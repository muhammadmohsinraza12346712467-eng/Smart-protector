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

-- Pocket Mode Dynamic Variables
_G.isInPocket = _G.isInPocket or false
_G.isLightDark = _G.isLightDark or false
_G.isProxNear = _G.isProxNear or false

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
      title="Smart Protector 3.0.0", use_sp="Use Smart Protector", sets="Settings", ex="Exit", ab="About", 
      s_en="Your system is secured now.", 
      s_dis="Security protection disabled.", 
      snd_al="Sound Alert", vib_al="Vib Alert", max_v="Max Volume Lock", use_lock="Use On Lock Screen",
      auto_using="Auto Lock While Using", timer_set="Select Inactivity Time",
      use_custom_snd="Use custom sound", sel_sound="Select your sound",
      chg_p="Use Charging Protection", vol_chn="Volume Channel", vol_med="Media", vol_rng="Ringtone", vol_alm="Alarm", chg_lng="Change Language", chg_pwd="Change PIN", save="SAVE", ok="OK", wrg="Wrong PIN", set_p="SET PIN", ent_p="ENTER PIN", 
      p_cls="The Smart Protector is closed.", 
      prox_warn="Remove hand from sensor!", 
      chg_en="Charging protection system initiated.", 
      chg_unl="Security protection disabled.", 
      sel_ln="Language", abt_text="Smart Protector Version 3.0.0\nUltimate Security Suite",
      use_intruder="Intruder Alert Protection",
      use_orientation="Orientation Lock (Face Down)",
      use_pocket="Pocket Mode Protection",
      intruder_warn="Too many wrong attempts! Locked for ",
      sec_unit=" seconds."
    },
    Urdu = {
      title="سمارٹ پروٹیکٹر 3.0.0", use_sp="پروٹیکٹر آن کریں", sets="سیٹنگز", ex="بند کریں", ab="معلومات", 
      s_en="Your system is secured now.", 
      s_dis="Security protection disabled.", 
      snd_al="آواز الرٹ", vib_al="وائبریشن الرٹ", 
      max_v="میکس والیوم لاک", 
      use_lock="لاک اسکرین پر", 
      auto_using="استعمال کے دوران آٹو لاک",
      timer_set="غیر فعال وقت منتخب کریں",
      use_custom_snd="اپنی مرضی کی آواز استعمال کریں", sel_sound="آواز منتخب کریں",
      chg_p="چارجنگ پروٹیکشن پر استعمال کریں", 
      vol_chn="والیوم چینل", vol_med="Media", vol_rng="Ringtone", vol_alm="Alarm", 
      chg_lng="زبان تبدیل کریں", 
      chg_pwd="پن تبدیل کریں", 
      save="محفوظ کریں", 
      ok="OK", wrg="غلط پن", set_p="پن سیٹ کریں", ent_p="پن درج کریں", 
      p_cls="The Smart Protector is closed.", 
      prox_warn="سینسر سے ہاتھ ہٹائیں!", 
      chg_en="Charging protection system initiated.", 
      chg_unl="Security protection disabled.", 
      sel_ln="زبان منتخب کریں", abt_text="سمارٹ پروٹیکٹر ورژن 3.0.0\nمفت اور مستقل پروٹیکشن۔",
      use_intruder="انٹروڈر الرٹ پروٹیکشن",
      use_orientation="اورینٹیشن لاک (الٹا فون)",
      use_pocket="پاکٹ موڈ پروٹیکشن",
      intruder_warn="بہت زیادہ غلط کوششیں۔ لاک کا وقت: ",
      sec_unit=" سیکنڈ۔"
    }
  }
  return T[lang] or T["English"]
end

local function applyOverlayFlags(dlg)
  local window = dlg.getWindow()
  window.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or 0x00080000)
  window.addFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or 0x00400000)
  window.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or 0x00200000)
end

-- ==================== [AUDIO ALERTS SYSTEM] ====================
local function playAlert(active)
  local channelName = _G.prefs.getString("selected_channel", "Media")
  local streamAttr = AudioAttributes.USAGE_MEDIA
  if channelName == "Alarm" then streamAttr = AudioAttributes.USAGE_ALARM 
  elseif channelName == "Ringtone" then streamAttr = AudioAttributes.USAGE_NOTIFICATION_RINGTONE end

  if active then
    if _G.isAlerting then return end
    _G.isAlerting = true
    cancelIdleTimer()
    acquireWake() 
    
    if _G.prefs.getBoolean("max_vol", false) then startHyperVolumeLock() end
    
    if _G.prefs.getBoolean("snd_a", true) then 
      pcall(function()
        if _G.mediaPlayer ~= nil then _G.mediaPlayer.release() end
        _G.mediaPlayer = MediaPlayer()
        
        local activeSoundPath = defaultSoundPath
        if _G.prefs.getBoolean("use_custom_snd", false) then
          local customP = _G.prefs.getString("custom_sound_path", "")
          if customP ~= "" and File(customP).exists() then
            activeSoundPath = customP
          end
        end

        _G.mediaPlayer.setDataSource(activeSoundPath)
        local audioAttributes = AudioAttributes.Builder().setUsage(streamAttr).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        _G.mediaPlayer.setAudioAttributes(audioAttributes)
        _G.mediaPlayer.setLooping(true)
        _G.mediaPlayer.prepare()
        _G.mediaPlayer.start()
      end)
    end
    if _G.prefs.getBoolean("vib_a", true) then vibrator.vibrate({0, 1000, 500}, 0) end
  else
    _G.isAlerting = false
    if _G.mediaPlayer ~= nil then pcall(function() _G.mediaPlayer.stop(); _G.mediaPlayer.release() end) _G.mediaPlayer = nil end
    vibrator.cancel()
    if not _G.isSecEnabled then releaseWake() end
  end
end

-- ==================== [INTRUDER PENALTY TIMER] ====================
local penaltyRunnable = nil
local function startIntruderPenalty(seconds)
  _G.isPenaltyActive = true
  _G.currentPenaltyTime = seconds
  local L = getL()
  
  bgSpeak(L.intruder_warn .. tostring(seconds) .. L.sec_unit)
  
  if penaltyRunnable ~= nil then
    mainHandler.removeCallbacks(penaltyRunnable)
  end

  penaltyRunnable = Runnable({
    run = function()
      _G.isPenaltyActive = false
      _G.currentPenaltyTime = 0
      penaltyRunnable = nil
    end
  })
  mainHandler.postDelayed(penaltyRunnable, seconds * 1000)
end

-- ==================== [SENSORS & SECURITY CONTROL] ====================
_G.toggleSec = function(enable, silent)
  local L = getL()
  pcall(function()
    if _G.m_listener then sensorManager.unregisterListener(_G.m_listener) end
    if _G.p_listener then sensorManager.unregisterListener(_G.p_listener) end
    if _G.o_listener then sensorManager.unregisterListener(_G.o_listener) end
    if _G.l_listener then sensorManager.unregisterListener(_G.l_listener) end
  end)
  
  if enable then
    _G.isSecEnabled = true
    _G.isInPocket = false
    _G.isLightDark = false
    _G.isProxNear = false
    cancelIdleTimer()
    acquireWake() 
    
    local isPocketEnabled = _G.prefs.getBoolean("use_pocket_mode", false)

    -- Proximity Sensor Listener
    _G.p_listener = SensorEventListener({
      onSensorChanged = function(event)
        local isNear = event.values[0] < event.sensor.getMaximumRange()
        _G.isProxNear = isNear

        if isPocketEnabled then
          if _G.isInPocket then
            if not isNear and not _G.isLightDark then
              _G.isInPocket = false
              _G.currentReason = "pocket"
              playAlert(true)
              _G.showPIN(false)
            end
          end
        else
          if isNear then 
            _G.isProximityBlocked = true
            _G.currentReason = "proximity"
            playAlert(true) 
          else
            _G.isProximityBlocked = false
            if _G.currentReason == "proximity" and not _G.isAlerting then playAlert(false) end
          end
        end
      end
    })

    -- Light Sensor Listener (For Pocket Mode)
    if isPocketEnabled then
      _G.l_listener = SensorEventListener({
        onSensorChanged = function(event)
          local lux = event.values[0]
          _G.isLightDark = (lux < 5) -- Low light threshold for pocket
          
          if _G.isProxNear and _G.isLightDark then
            _G.isInPocket = true
          elseif not _G.isProxNear and not _G.isLightDark and _G.isInPocket then
            _G.isInPocket = false
            _G.currentReason = "pocket"
            playAlert(true)
            _G.showPIN(false)
          end
        end
      })
      local lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT or 5)
      if lightSensor then
        sensorManager.registerListener(_G.l_listener, lightSensor, SensorManager.SENSOR_DELAY_FASTEST)
      end
    end
    
    -- Motion Sensor Listener
    _G.m_listener = SensorEventListener({
      onSensorChanged = function(event)
        if _G.isAlerting then return end
        if isPocketEnabled and _G.isInPocket then return end
        
        local g = math.sqrt(event.values[0]^2 + event.values[1]^2 + event.values[2]^2)
        if math.abs(g - 9.8) > 1.5 then 
          _G.currentReason = "motion"
          playAlert(true) 
          if not _G.isProximityBlocked then _G.showPIN(false) end
        end
      end
    })
    
    -- Orientation Sensor Listener (Face Down Detection)
    if _G.prefs.getBoolean("use_orientation_lock", false) then
      _G.o_listener = SensorEventListener({
        onSensorChanged = function(event)
          if _G.isAlerting then return end
          if isPocketEnabled and _G.isInPocket then return end
          
          local pitch = event.values[1]
          if pitch < -70 or pitch > 70 then
            if not _G.isOrientationLockActive then
              _G.isOrientationLockActive = true
              _G.currentReason = "orientation"
              playAlert(true)
              if not _G.isProximityBlocked then _G.showPIN(false) end
            end
          else
            _G.isOrientationLockActive = false
          end
        end
      })
      sensorManager.registerListener(_G.o_listener, sensorManager.getDefaultSensor(Sensor.TYPE_ORIENTATION or 3), SensorManager.SENSOR_DELAY_NORMAL)
    end
    
    sensorManager.registerListener(_G.p_listener, sensorManager.getDefaultSensor(8), SensorManager.SENSOR_DELAY_FASTEST)
    sensorManager.registerListener(_G.m_listener, sensorManager.getDefaultSensor(1), SensorManager.SENSOR_DELAY_FASTEST)
    if not silent then bgSpeak(L.s_en) end
  else
    _G.isSecEnabled = false
    _G.isProximityBlocked = false
    _G.isOrientationLockActive = false
    _G.isInPocket = false
    playAlert(false)
    releaseWake()
    if not silent then bgSpeak(L.s_dis) end 
    startIdleTimer()
  end
end

-- ==================== [PIN PAD CORE] ====================
_G.showPIN = function(isNew)
  local L = getL()
  if _G.isProximityBlocked and not isNew and not _G.prefs.getBoolean("use_pocket_mode", false) then return true end
  
  if _G.isPenaltyActive and not isNew then
    bgSpeak(L.intruder_warn .. tostring(_G.currentPenaltyTime) .. L.sec_unit)
    return true
  end
  
  local passDialog = createManagedDialog("PIN")
  if passDialog == nil then return true end 
  _G.isPinPadOpen = true
  
  local ent = ""
  passDialog.setTitle(isNew and L.set_p or L.ent_p)
  
  local mainLay = LinearLayout(service).setOrientation(1).setGravity(Gravity.CENTER)
  mainLay.setPadding(40, 40, 40, 40).setBackgroundColor(0xEE000000)
  
  local txt = TextView(service).setText(isNew and L.set_p or L.ent_p)
  txt.setTextSize(25).setTextColor(0xFFFFFFFF).setPadding(0, 0, 0, 20)
  mainLay.addView(txt)
  
  local grid = GridLayout(service).setColumnCount(3)
  
  local function handlePinSuccess()
    if _G.isProximityBlocked and not _G.prefs.getBoolean("use_pocket_mode", false) then
      bgSpeak(L.prox_warn)
      ent = ""; txt.setText("")
      return
    end
    
    _G.failedAttempts = 0
    clearUiState()
    playAlert(false) 
    
    if _G.currentReason == "charging" then
      bgSpeak(L.chg_unl) 
      _G.isChargingActive = false
    else
      _G.toggleSec(false, false)
    end
  end

  local function handlePinFailure()
    ent = ""; txt.setText("")
    _G.failedAttempts = _G.failedAttempts + 1
    
    local isIntruderEnabled = _G.prefs.getBoolean("use_intruder_alert", false)
    if isIntruderEnabled and _G.failedAttempts >= 3 then
      local penalty = (_G.failedAttempts - 2) * 10
      clearUiState()
      startIntruderPenalty(penalty)
    else
      bgSpeak(L.wrg)
    end
  end
  
  local function handleFirstRunRegistration()
    _G.prefs.edit().putString("pass", ent).putBoolean("first_run_done", true).commit()
    clearUiState()
    mainHandler.post(Runnable({run = function() _G.showMainUI() end}))
  end
  
  for _, v in ipairs({"1","2","3","4","5","6","7","8","9","C","0","OK"}) do
    local b = Button(service).setText(v).setTextSize(18)
    b.setOnClickListener(function()
      _G.resetUserActivity()
      if v == "C" then ent = ""; txt.setText("")
      elseif v == "OK" then
        if isNew and #ent >= 4 then handleFirstRunRegistration()
        elseif not isNew and ent == _G.prefs.getString("pass", "0000") then handlePinSuccess()
        elseif ent ~= "" then handlePinFailure() end
      else 
        ent = ent .. v 
        txt.setText(string.rep("● ", #ent))
        if #ent == 4 then
          if isNew then handleFirstRunRegistration()
          else
            if ent == _G.prefs.getString("pass", "0000") then handlePinSuccess()
            else handlePinFailure() end
          end
        end
      end
      return true 
    end)
    grid.addView(b)
  end
  
  mainLay.addView(grid)
  passDialog.setView(mainLay)
  applyOverlayFlags(passDialog)
  passDialog.show()
  return true
end

-- ==================== [FILE PICKER DIALOG] ====================
openFilePicker = function(currentDirPath)
  currentDirPath = currentDirPath or "/storage/emulated/0"
  local fileDialog = createManagedDialog("FILE_PICKER")
  if fileDialog == nil then return end

  fileDialog.setTitle("Select your sound")

  local mainLayout = LinearLayout(service).setOrientation(1).setPadding(30, 30, 30, 30)
  
  local pathTxt = TextView(service).setText(currentDirPath)
  pathTxt.setTextSize(13).setTextColor(0xAAFFFFFF).setPadding(0, 0, 0, 15)
  mainLayout.addView(pathTxt)

  local listView = ListView(service)
  listView.setFocusable(true)
  listView.setClickable(true)
  mainLayout.addView(listView, LinearLayout.LayoutParams(-1, 0, 1))

  local dirFile = File(currentDirPath)
  local fileList = {}
  
  if dirFile.getParent() ~= nil then
    table.insert(fileList, { name = ".. (Parent Folder)", isDir = true, path = dirFile.getParent() })
  end

  local javaFilesArray = dirFile.listFiles()
  if javaFilesArray ~= nil then
    local luaFilesTable = luajava.astable(javaFilesArray)
    for _, f in ipairs(luaFilesTable) do
      local name = f.getName()
      local isDirectory = f.isDirectory()
      
 