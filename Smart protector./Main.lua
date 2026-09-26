require "import"
import "android.widget.*"
import "android.view.*"
import "android.app.*"
import "android.content.*"
import "android.hardware.*"
import "android.media.*"
import "android.os.*"
import "android.graphics.*"
import "android.speech.tts.*"
import "java.io.File"

-- ==================== [GLOBAL CONFIGURATION & VARIABLES] ====================
_G.prefs = service.getSharedPreferences("SP_BACKGROUND_UNIQUE_PHRASES_V41", 0)
local sensorManager = service.getSystemService(Context.SENSOR_SERVICE)
local audioManager = service.getSystemService(Context.AUDIO_SERVICE)
local vibrator = service.getSystemService(Context.VIBRATOR_SERVICE)
local powerManager = service.getSystemService(Context.POWER_SERVICE)
local mainHandler = Handler(Looper.getMainLooper())
local defaultSoundPath = "/storage/emulated/0/解说/Plugins/Smart protector/voice/Loud Alarm Sound Effect(MP3_160K).mp3"

_G.isAlerting = _G.isAlerting or false
_G.isPinPadOpen = _G.isPinPadOpen or false
_G.isSecEnabled = _G.isSecEnabled or false
_G.isProximityBlocked = _G.isProximityBlocked or false
_G.isChargingActive = _G.isChargingActive or false

-- New State Variables
_G.failedAttempts = _G.failedAttempts or 0
_G.currentPenaltyTime = _G.currentPenaltyTime or 0
_G.isPenaltyActive = _G.isPenaltyActive or false
_G.isOrientationLockActive = _G.isOrientationLockActive or false

_G.currentUiState = "NONE" 
local globalDialog = nil
_G.currentReason = _G.currentReason or "motion"
local wakeLock = nil

-- Forward Declarations
local openSettings = nil
local openAboutApp = nil
local openChannelSelector = nil
local openInactivityTimerSelector = nil
local openFilePicker = nil

-- ==================== [TTS ENGINE SETUP] ====================
local ttsEngine = nil
local isTtsReady = false
local pendingSpeech = nil

local function bgSpeak(text)
  mainHandler.post(Runnable({
    run = function()
      if ttsEngine ~= nil and isTtsReady then
        pcall(function() ttsEngine.speak(text, TextToSpeech.QUEUE_FLUSH, nil, "SmartProtectorTTS") end)
      else
        pendingSpeech = text
        pcall(function() service.speak(text, 1) end)
      end
    end
  }))
end

local function initTts(onReadyCallback)
  if ttsEngine == nil then
    pcall(function()
      ttsEngine = TextToSpeech(service, TextToSpeech.OnInitListener({
        onInit = function(status)
          if status == TextToSpeech.SUCCESS then
            isTtsReady = true
            if pendingSpeech ~= nil then
              bgSpeak(pendingSpeech)
              pendingSpeech = nil
            end
            if onReadyCallback then onReadyCallback() end
          end
        end
      }))
    end)
  else
    if isTtsReady and onReadyCallback then onReadyCallback() end
  end
end

-- ==================== [INACTIVITY & MEDIA MONITOR] ====================
local idleRunnable = nil

local function cancelIdleTimer()
  if idleRunnable ~= nil then
    mainHandler.removeCallbacks(idleRunnable)
    idleRunnable = nil
  end
end

local function startIdleTimer()
  cancelIdleTimer()
  
  local isAutoLockWhileUsing = _G.prefs.getBoolean("auto_lock_using", true)
  if not isAutoLockWhileUsing or _G.isSecEnabled or _G.isAlerting or audioManager.isMusicActive() then
    return 
  end

  local idleTimeMs = _G.prefs.getInt("inactivity_interval", 60000)

  idleRunnable = Runnable({
    run = function()
      if not audioManager.isMusicActive() and not _G.isSecEnabled then
        _G.toggleSec(true, false)
      end
      idleRunnable = nil
    end
  })
  
  mainHandler.postDelayed(idleRunnable, idleTimeMs)
end

_G.resetUserActivity = function()
  if not _G.isSecEnabled then
    startIdleTimer()
  end
end

local function getAndroidStreamType()
  local channelName = _G.prefs.getString("selected_channel", "Media")
  if channelName == "Alarm" then
    return AudioManager.STREAM_ALARM
  elseif channelName == "Ringtone" then
    return AudioManager.STREAM_RING
  else
    return AudioManager.STREAM_MUSIC
  end
end

-- ==================== [VOLUME LOCK LOOP] ====================
local volEnforcerLoop = nil
local function startHyperVolumeLock()
  if volEnforcerLoop ~= nil then return end 
  
  volEnforcerLoop = Runnable({
    run = function()
      if _G.isAlerting and _G.prefs.getBoolean("max_vol", false) then
        local streamType = getAndroidStreamType()
        pcall(function()
          local maxVol = audioManager.getStreamMaxVolume(streamType)
          local currentVol = audioManager.getStreamVolume(streamType)
          if currentVol < maxVol then
            audioManager.setStreamVolume(streamType, maxVol, 0)
          end
        end)
        mainHandler.postDelayed(volEnforcerLoop, 50) 
      else
        volEnforcerLoop = nil 
      end
    end
  })
  mainHandler.post(volEnforcerLoop)
end

-- ==================== [DIALOG MANAGEMENT] ====================
local function clearUiState()
  if globalDialog ~= nil then
    pcall(function() globalDialog.dismiss() end)
    globalDialog = nil
  end
  _G.currentUiState = "NONE"
  _G.isPinPadOpen = false
end

local function createManagedDialog(stateName)
  if _G.currentUiState == stateName and globalDialog ~= nil then
    return nil 
  end
  clearUiState()
  _G.currentUiState = stateName
  globalDialog = LuaDialog(service)
  globalDialog.setCancelable(false)
  return globalDialog
end

local function acquireWake()
  pcall(function()
    if wakeLock == nil then
      wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK or 1, "SmartProtector::GlobalSystemWake")
      wakeLock.acquire()
    end
  end)
end

local function releaseWake()
  pcall(function()
    if wakeLock ~= nil and wakeLock.isHeld() then
      wakeLock.release()
      wakeLock = nil
    end
  end)
end

-- ==================== [LANGUAGES & PHRASES] ====================
local function getL()
  local lang = _G.prefs.getString("lang", "English")
  local T = {
    English = {
      title="Smart Protector 3.0", use_sp="Use Smart Protector", sets="Settings", ex="Exit", ab="About", 
      s_en="Your system is secured now.", 
      s_dis="Security protection disabled.", 
      snd_al="Sound Alert", vib_al="Vib Alert", max_v="Max Volume Lock", use_lock="... Read more