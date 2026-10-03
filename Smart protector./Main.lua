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
_G.currentLightLux = 1000
_G.isPocketActive = false
_G.light_listener = nil
_G.pocketWatcherActive = false
_G.pocketWatcher_p_listener = nil
_G.pocketWatcher_l_listener = nil
_G.currentUiState = "NONE"
local globalDialog = nil
_G.currentReason = _G.currentReason or "motion"
local wakeLock = nil

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
            if pendingSpeech ~= nil then bgSpeak(pendingSpeech) pendingSpeech = nil end
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
  if idleRunnable ~= nil then mainHandler.removeCallbacks(idleRunnable) idleRunnable = nil end
end
local function startIdleTimer()
  cancelIdleTimer()
  local isAutoLockWhileUsing = _G.prefs.getBoolean("auto_lock_using", true)
  if not isAutoLockWhileUsing or _G.isSecEnabled or _G.isAlerting or audioManager.isMusicActive() then return end
  local idleTimeMs = _G.prefs.getInt("inactivity_interval", 60000)
  idleRunnable = Runnable({run = function()
    if not audioManager.isMusicActive() and not _G.isSecEnabled then _G.toggleSec(true, false) end
    idleRunnable = nil
  end})
  mainHandler.postDelayed(idleRunnable, idleTimeMs)
end
_G.resetUserActivity = function() if not _G.isSecEnabled then startIdleTimer() end end

local function getAndroidStreamType()
  local channelName = _G.prefs.getString("selected_channel", "Media")
  if channelName == "Alarm" then return AudioManager.STREAM_ALARM
  elseif channelName == "Ringtone" then return AudioManager.STREAM_RING
  else return AudioManager.STREAM_MUSIC end
end

-- ==================== [VOLUME LOCK LOOP] ====================
local volEnforcerLoop = nil
local function startHyperVolumeLock()
  if volEnforcerLoop ~= nil then return end
  volEnforcerLoop = Runnable({run = function()
    if _G.isAlerting and _G.prefs.getBoolean("max_vol", false) then
      local streamType = getAndroidStreamType()
      pcall(function()
        local maxVol = audioManager.getStreamMaxVolume(streamType)
        if audioManager.getStreamVolume(streamType) < maxVol then audioManager.setStreamVolume(streamType, maxVol, 0) end
      end)
      mainHandler.postDelayed(volEnforcerLoop, 50)
    else volEnforcerLoop = nil end
  end})
  mainHandler.post(volEnforcerLoop)
end

-- ==================== [DIALOG MANAGEMENT] ====================
local function clearUiState()
  if globalDialog ~= nil then pcall(function() globalDialog.dismiss() end) globalDialog = nil end
  _G.currentUiState = "NONE"
  _G.isPinPadOpen = false
end
local function createManagedDialog(stateName)
  if _G.currentUiState == stateName and globalDialog ~= nil then return nil end
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
  pcall(function() if wakeLock ~= nil and wakeLock.isHeld() then wakeLock.release() wakeLock = nil end end)
end

-- ==================== [FINGERPRINT - FIXED - SAME FORMAT - NO ERROR - WILL TURN ON] ====================
_G.currentFpPrompt = nil
_G.verifyFingerprint = function(isSetupMode, onSuccess, onFailed)
  mainHandler.post(Runnable({
    run = function()
      pcall(function() if _G.currentFpPrompt ~= nil then _G.currentFpPrompt.cancelAuthentication() _G.currentFpPrompt = nil end end)
      local ok, err = pcall(function()
        local BiometricManager = luajava.bindClass("androidx.biometric.BiometricManager")
        local BiometricPrompt = luajava.bindClass("androidx.biometric.BiometricPrompt")
        local PromptInfo = luajava.bindClass("androidx.biometric.BiometricPrompt$PromptInfo")
        local ContextCompat = luajava.bindClass("androidx.core.content.ContextCompat")
        local bm = BiometricManager.from(service)
        local canAuth = bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        if canAuth == BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE then bgSpeak("No fingerprint hardware") if onFailed then onFailed() end return end
        if canAuth == BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED then bgSpeak("No fingerprint enrolled in phone settings") if onFailed then onFailed() end return end
        if canAuth ~= BiometricManager.BIOMETRIC_SUCCESS then bgSpeak("Fingerprint not ready") if onFailed then onFailed() end return end
        bgSpeak(isSetupMode and "Touch sensor now to save" or "Touch sensor now to unlock")
        local executor = nil
        pcall(function() executor = ContextCompat.getMainExecutor(service) end)
        if executor == nil then pcall(function() executor = service.getMainExecutor() end) end
        local callback = luajava.createProxy("androidx.biometric.BiometricPrompt$AuthenticationCallback", {
          onAuthenticationSucceeded = function(result)
            mainHandler.post(Runnable({run = function()
              _G.currentFpPrompt = nil
              if isSetupMode then _G.prefs.edit().putBoolean("fp_verified", true).putBoolean("fp_enabled", true).commit() bgSpeak("Verify complete. Fingerprint saved") else bgSpeak("Fingerprint verified") end
              vibrator.vibrate(80)
              if onSuccess then onSuccess() end
            end}))
          end,
          onAuthenticationFailed = function()
            mainHandler.post(Runnable({run = function() bgSpeak("Wrong fingerprint. Try again") vibrator.vibrate({0,80,80,80}, -1) end}))
          end,
          onAuthenticationError = function(errorCode, errString)
            mainHandler.post(Runnable({run = function() _G.currentFpPrompt = nil if errorCode ~= 10 and errorCode ~= 13 and errorCode ~= 5 then bgSpeak(tostring(errString)) end if onFailed then onFailed() end end}))
          end
        })
        local prompt = nil
        pcall(function() prompt = BiometricPrompt(service, executor, callback) end)
        if prompt == nil and globalDialog ~= nil then pcall(function() prompt = BiometricPrompt(globalDialog.getContext(), executor, callback) end) end
        if prompt == nil then bgSpeak("Cannot create fingerprint prompt") if onFailed then onFailed() end return end
        local promptInfo = PromptInfo.Builder().setTitle(isSetupMode and "Save Fingerprint" or "Smart Protector").setSubtitle(isSetupMode and "Touch sensor to save - One time" or "Touch sensor to unlock").setNegativeButtonText(isSetupMode and "Cancel" or "Use PIN").build()
        _G.currentFpPrompt = prompt
        prompt.authenticate(promptInfo)
      end)
      if not ok then bgSpeak("Fingerprint error: ".. tostring(err)) if onFailed then onFailed() end end
    end
  }))
end

-- ==================== [LANGUAGES & PHRASES] ====================
local function getL()
  local lang = _G.prefs.getString("lang", "English")
  local T = {
    English = {
      title="Smart Protector 2.0", use_sp="Use Smart Protector", sets="Settings", ex="Exit", ab="About",
      s_en="Your system is secured now.", s_dis="Security protection disabled.",
      snd_al="Sound Alert", vib_al="Vib Alert", max_v="Max Volume Lock", use_lock="Use On Lock Screen",
      auto_using="Auto Lock While Using", timer_set="Select Inactivity Time",
      use_custom_snd="Use custom sound", sel_sound="Select your sound",
      chg_p="Use Charging Protection", pocket_p="Pocket Mode (Proximity + Light)", use_fp="Fingerprint Unlock (Sensor)", vol_chn="Volume Channel", vol_med="Media", vol_rng="Ringtone", vol_alm="Alarm", chg_lng="Change Language", chg_pwd="Change PIN", save="SAVE", ok="OK", wrg="Wrong PIN", set_p="SET PIN", ent_p="ENTER PIN",
      p_cls="Closed - Pocket mode still watching.", prox_warn="Remove hand from sensor!",
      pocket_en="Pocket mode secured.", chg_en="Charging protection on.", chg_unl="Security disabled.",
      fp_btn="Touch Fingerprint Sensor", fp_verify="Verify Fingerprint (Touch Sensor)",
      sel_ln="Language", abt_text="Smart Protector 2.0\nPocket + Direct Sensor"
    },
    Urdu = {
      title="سمارٹ پروٹیکٹر 2.0", use_sp="پروٹیکٹر آن کریں", sets="سیٹنگز", ex="بند کریں", ab="معلومات",
      s_en="Your system is secured now.", s_dis="Security protection disabled.",
      snd_al="آواز الرٹ", vib_al="وائبریشن الرٹ", max_v="میکس والیوم لاک", use_lock="لاک اسکرین پر",
      auto_using="استعمال کے دوران آٹو لاک", timer_set="غیر فعال وقت منتخب کریں",
      use_custom_snd="اپنی مرضی کی آواز استعمال کریں", sel_sound="آواز منتخب کریں",
      chg_p="چارجنگ پروٹیکشن پر استعمال کریں", pocket_p="پاکٹ موڈ (پروکسیمٹی + لائٹ)", use_fp="فنگر پرنٹ انلاک (سینسر)",
      vol_chn="والیوم چینل", vol_med="Media", vol_rng="Ringtone", vol_alm="Alarm",
      chg_lng="زبان تبدیل کریں", chg_pwd="پن تبدیل کریں", save="محفوظ کریں",
      ok="OK", wrg="غلط پن", set_p="پن سیٹ کریں", ent_p="پن درج کریں",
      p_cls="بند ہے - پاکٹ موڈ ابھی بھی دیکھ رہا ہے", prox_warn="سینسر سے ہاتھ ہٹائیں!",
      pocket_en="Pocket mode secured.", chg_en="Charging protection on.", chg_unl="Security disabled.",
      fp_btn="فنگر پرنٹ سینسر کو ٹچ کریں", fp_verify="فنگر پرنٹ تصدیق کریں",
      sel_ln="زبان منتخب کریں", abt_text="Smart Protector 2.0\nPocket + Direct Sensor"
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
          if customP ~= "" and File(customP).exists() then activeSoundPath = customP end
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

-- ==================== [POCKET MODE - PROXIMITY + LIGHT + 10 SEC - YOUR FORMAT - FIXED] ====================
local pocketCoverTimer = nil
local isPocketCoverCounting = false

local function cancelPocketCoverTimer()
  if pocketCoverTimer ~= nil then mainHandler.removeCallbacks(pocketCoverTimer) pocketCoverTimer = nil end
  isPocketCoverCounting = false
end

local function checkPocketState()
  if not _G.prefs.getBoolean("pocket_p_enabled", false) then cancelPocketCoverTimer() return end
  local LIGHT_THRESHOLD = _G.prefs.getInt("pocket_light_threshold", 15)
  local isDark = _G.currentLightLux <= LIGHT_THRESHOLD
  local isNear = _G.isProximityBlocked
  local isInPocketNow = isDark and isNear
  if isInPocketNow then
    if not _G.isPocketActive and not _G.isSecEnabled and not isPocketCoverCounting then
      isPocketCoverCounting = true
      bgSpeak("Pocket detected. Checking 10 seconds")
      pocketCoverTimer = Runnable({run = function()
        pocketCoverTimer = nil
        isPocketCoverCounting = false
        local stillDark = _G.currentLightLux <= LIGHT_THRESHOLD
        local stillNear = _G.isProximityBlocked
        if stillDark and stillNear and not _G.isSecEnabled then
          _G.isPocketActive = true
          bgSpeak("Pocket mode secured")
          _G.toggleSec(true, true)
        end
      end})
      mainHandler.postDelayed(pocketCoverTimer, 10000)
    end
  else
    if isPocketCoverCounting then cancelPocketCoverTimer() end
    if _G.isPocketActive and _G.isSecEnabled then
      _G.currentReason = "pocket"
      playAlert(true)
      _G.showPIN(false)
    end
  end
end

_G.startPocketWatcher = function()
  if not _G.prefs.getBoolean("pocket_p_enabled", false) then return end
  if _G.pocketWatcherActive then return end
  pcall(function()
    if _G.pocketWatcher_p_listener then sensorManager.unregisterListener(_G.pocketWatcher_p_listener) end
    if _G.pocketWatcher_l_listener then sensorManager.unregisterListener(_G.pocketWatcher_l_listener) end
  end)
  cancelPocketCoverTimer()
  _G.pocketWatcher_p_listener = SensorEventListener({
    onSensorChanged = function(event)
      _G.isProximityBlocked = event.values[0] < event.sensor.getMaximumRange()
      checkPocketState()
    end
  })
  _G.pocketWatcher_l_listener = SensorEventListener({
    onSensorChanged = function(event)
      _G.currentLightLux = event.values[0]
      checkPocketState()
    end
  })
  sensorManager.registerListener(_G.pocketWatcher_p_listener, sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY), SensorManager.SENSOR_DELAY_NORMAL)
  local ls = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
  if ls ~= nil then sensorManager.registerListener(_G.pocketWatcher_l_listener, ls, SensorManager.SENSOR_DELAY_NORMAL) end
  _G.pocketWatcherActive = true
end

_G.stopPocketWatcher = function()
  pcall(function()
    if _G.pocketWatcher_p_listener then sensorManager.unregisterListener(_G.pocketWatcher_p_listener) end
    if _G.pocketWatcher_l_listener then sensorManager.unregisterListener(_G.pocketWatcher_l_listener) end
  end)
  cancelPocketCoverTimer()
  _G.pocketWatcherActive = false
end

-- ==================== [SENSORS & SECURITY CONTROL] ====================
_G.toggleSec = function(enable, silent)
  local L = getL()
  pcall(function()
    if _G.m_listener then sensorManager.unregisterListener(_G.m_listener) end
    if _G.p_listener then sensorManager.unregisterListener(_G.p_listener) end
    if _G.light_listener then sensorManager.unregisterListener(_G.light_listener) end
  end)
  if enable then
    _G.isSecEnabled = true
    cancelIdleTimer()
    acquireWake()
    _G.stopPocketWatcher()
    _G.p_listener = SensorEventListener({
      onSensorChanged = function(event)
        _G.isProximityBlocked = event.values[0] < event.sensor.getMaximumRange()
        if not _G.prefs.getBoolean("pocket_p_enabled", false) and _G.isProximityBlocked then
          _G.currentReason = "proximity"
          playAlert(true)
        elseif not _G.isProximityBlocked and _G.currentReason == "proximity" then
          playAlert(false)
        end
        checkPocketState()
      end
    })
    _G.light_listener = SensorEventListener({
      onSensorChanged = function(event) _G.currentLightLux = event.values[0] checkPocketState() end
    })
    _G.m_listener = SensorEventListener({
      onSensorChanged = function(event)
        if _G.isAlerting and _G.currentReason == "motion" then return end
        if _G.isPocketActive then return end
        local g = math.sqrt(event.values[0]^2 + event.values[1]^2 + event.values[2]^2)
        if math.abs(g - 9.8) > 1.5 then
          _G.currentReason = "motion"
          playAlert(true)
          if not _G.isProximityBlocked then _G.showPIN(false) end
        end
      end
    })
    sensorManager.registerListener(_G.p_listener, sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY), SensorManager.SENSOR_DELAY_FASTEST)
    sensorManager.registerListener(_G.m_listener, sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER), SensorManager.SENSOR_DELAY_FASTEST)
    local lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
    if lightSensor ~= nil then sensorManager.registerListener(_G.light_listener, lightSensor, SensorManager.SENSOR_DELAY_NORMAL) end
    if not silent then bgSpeak(L.s_en) end
  else
    _G.isSecEnabled = false
    _G.isPocketActive = false
    _G.isProximityBlocked = false
    playAlert(false)
    releaseWake()
    if not silent then bgSpeak(L.s_dis) end
    startIdleTimer()
    if _G.prefs.getBoolean("pocket_p_enabled", false) then
      mainHandler.postDelayed(Runnable({run = function() _G.startPocketWatcher() end}), 1000)
    end
  end
end

-- ==================== [PIN PAD CORE WITH FINGERPRINT SENSOR] ====================
_G.showPIN = function(isNew)
  local L = getL()
  if _G.isProximityBlocked and not isNew and not _G.prefs.getBoolean("pocket_p_enabled", false) then return true end
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

  local function handlePinSuccess()
    if _G.isProximityBlocked and not _G.prefs.getBoolean("pocket_p_enabled", false) then bgSpeak(L.prox_warn) ent = ""; txt.setText("") return end
    pcall(function() if _G.currentFpPrompt ~= nil then _G.currentFpPrompt.cancelAuthentication() _G.currentFpPrompt = nil end end)
    clearUiState()
    playAlert(false)
    _G.isPocketActive = false
    if _G.currentReason == "charging" then bgSpeak(L.chg_unl) _G.isChargingActive = false
    else _G.toggleSec(false, false) end
  end

  if not isNew and _G.prefs.getBoolean("fp_enabled", false) and _G.prefs.getBoolean("fp_verified", false) then
    local fpBtn = Button(service).setText(L.fp_btn)
    fpBtn.setBackgroundColor(0xFF2196F3)
    fpBtn.setTextColor(0xFFFFFFFF)
    fpBtn.setOnClickListener(function()
      _G.verifyFingerprint(false, function() handlePinSuccess() end, function() end)
    end)
    mainLay.addView(fpBtn, LinearLayout.LayoutParams(-1, -2).setMargins(0,0,0,20))
    mainHandler.postDelayed(Runnable({run = function()
      if _G.isPinPadOpen then _G.verifyFingerprint(false, function() handlePinSuccess() end, function() end) end
    end}), 700)
  end

  local grid = GridLayout(service).setColumnCount(3)
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
        elseif ent!= "" then ent = ""; bgSpeak(L.wrg); txt.setText("") end
      else
        ent = ent.. v
        txt.setText(string.rep("● ", #ent))
        if #ent == 4 then
          if isNew then handleFirstRunRegistration()
          else
            if ent == _G.prefs.getString("pass", "0000") then handlePinSuccess()
            else ent = ""; txt.setText(""); bgSpeak(L.wrg) end
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
  mainLayout.addView(listView, LinearLayout.LayoutParams(-1, 0, 1))
  local dirFile = File(currentDirPath)
  local fileList = {}
  if dirFile.getParent() ~= nil then table.insert(fileList, { name = ".. (Parent Folder)", isDir = true, path = dirFile.getParent() }) end
  local javaFilesArray = dirFile.listFiles()
  if javaFilesArray ~= nil then
    local luaFilesTable = luajava.astable(javaFilesArray)
    for _, f in ipairs(luaFilesTable) do
      local name = f.getName()
      if f.isDirectory() then table.insert(fileList, { name = "📁 ".. name, isDir = true, path = f.getAbsolutePath() })
      else
        local lower = name:lower()
        if lower:find("%.mp3$") or lower:find("%.wav$") or lower:find("%.m4a$") or lower:find("%.ogg$") then
          table.insert(fileList, { name = "🎵 ".. name, isDir = false, path = f.getAbsolutePath() })
        end
      end
    end
  end
  local adapterItems = {}
  for _, item in ipairs(fileList) do table.insert(adapterItems, item.name) end
  listView.setAdapter(ArrayAdapter(service, android.R.layout.simple_list_item_1, adapterItems))
  listView.setOnItemClickListener(AdapterView.OnItemClickListener({
    onItemClick = function(parent, view, position, id)
      local selected = fileList[position + 1]
      if selected ~= nil then
        if selected.isDir then clearUiState() mainHandler.post(Runnable({run = function() openFilePicker(selected.path) end}))
        else _G.prefs.edit().putString("custom_sound_path", selected.path).commit() bgSpeak("Sound Selected") clearUiState() openSettings() end
      end
    end
  }))
  local btnCancel = Button(service).setText("Cancel")
  btnCancel.setOnClickListener(function() clearUiState(); openSettings() end)
  mainLayout.addView(btnCancel)
  fileDialog.setView(mainLayout)
  applyOverlayFlags(fileDialog)
  fileDialog.show()
end

-- ==================== [LANGUAGE & SETTINGS DIALOGS] ====================
_G.showLanguageSelect = function(forceReset)
  local langDialog = createManagedDialog("LANG")
  if langDialog == nil then return end
  langDialog.setTitle("Language")
  local lay = LinearLayout(service).setOrientation(1).setPadding(30, 30, 30, 30)
  local function proceedNextStep(langSelected)
    _G.prefs.edit().putString("lang", langSelected).commit()
    clearUiState()
    if forceReset then _G.showMainUI() else mainHandler.post(Runnable({run = function() _G.showPIN(true) end})) end
  end
  local bEn = Button(service).setText("English")
  bEn.setOnClickListener(function() proceedNextStep("English") end)
  local bUr = Button(service).setText("Urdu")
  bUr.setOnClickListener(function() proceedNextStep("Urdu") end)
  lay.addView(bEn); lay.addView(bUr);
  langDialog.setView(lay); applyOverlayFlags(langDialog); langDialog.show()
end

openAboutApp = function()
  local L = getL()
  local aboutDialog = createManagedDialog("ABOUT")
  if aboutDialog == nil then return end
  aboutDialog.setTitle(L.ab)
  local lay = LinearLayout(service).setOrientation(1).setPadding(30, 30, 30, 30)
  local txt = TextView(service).setText(L.abt_text).setTextSize(15).setTextColor(0xFFFFFFFF)
  local btn = Button(service).setText(L.ok)
  btn.setOnClickListener(function() clearUiState(); _G.showMainUI() end)
  lay.addView(txt, LinearLayout.LayoutParams(-1, -2)); lay.addView(btn)
  aboutDialog.setView(lay); applyOverlayFlags(aboutDialog); aboutDialog.show()
end

openChannelSelector = function()
  local L = getL()
  local channelDialog = createManagedDialog("CHANNEL")
  if channelDialog == nil then return end
  channelDialog.setTitle(L.vol_chn)
  local lay = LinearLayout(service).setOrientation(1).setPadding(35, 35, 35, 35)
  local bAlarm = Button(service).setText(L.vol_alm)
  bAlarm.setOnClickListener(function() _G.prefs.edit().putString("selected_channel", "Alarm").commit(); openSettings() end)
  local bMedia = Button(service).setText(L.vol_med)
  bMedia.setOnClickListener(function() _G.prefs.edit().putString("selected_channel", "Media").commit(); openSettings() end)
  local bRing = Button(service).setText(L.vol_rng)
  bRing.setOnClickListener(function() _G.prefs.edit().putString("selected_channel", "Ringtone").commit(); openSettings() end)
  lay.addView(bAlarm); lay.addView(bMedia); lay.addView(bRing)
  channelDialog.setView(lay); applyOverlayFlags(channelDialog); channelDialog.show()
end

openInactivityTimerSelector = function()
  local L = getL()
  local timerDialog = createManagedDialog("TIMER_SELECT")
  if timerDialog == nil then return end
  timerDialog.setTitle(L.timer_set)
  local lay = LinearLayout(service).setOrientation(1).setPadding(35, 35, 35, 35)
  local opts = {{ text = "1 Minute", ms = 60000 },{ text = "2 Minutes", ms = 120000 },{ text = "3 Minutes", ms = 180000 },{ text = "4 Minutes", ms = 240000 },{ text = "5 Minutes", ms = 300000 }}
  for _, opt in ipairs(opts) do
    local b = Button(service).setText(opt.text)
    b.setOnClickListener(function() _G.prefs.edit().putInt("inactivity_interval", opt.ms).commit() startIdleTimer() openSettings() end)
    lay.addView(b)
  end
  timerDialog.setView(lay); applyOverlayFlags(timerDialog); timerDialog.show()
end

openSettings = function()
  local L = getL()
  local settingsDialog = createManagedDialog("SETTINGS")
  if settingsDialog == nil then return end
  settingsDialog.setTitle(L.sets)
  local isCustomSndChecked = _G.prefs.getBoolean("use_custom_snd", false)
  local layout = {
    ScrollView; layout_width = "fill";
    { LinearLayout; orientation = "vertical"; padding = "30dp";
      { Switch; id = "sSnd"; text = L.snd_al; textSize = "16sp"; checked = _G.prefs.getBoolean("snd_a", true); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sCustomSnd"; text = L.use_custom_snd; textSize = "16sp"; checked = isCustomSndChecked; layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Button; id = "btnSelectSound"; text = L.sel_sound; textSize = "15sp"; layout_width = "fill"; layout_marginBottom = "10dp"; visibility = isCustomSndChecked and 0 or 8; };
      { Switch; id = "sVib"; text = L.vib_al; textSize = "16sp"; checked = _G.prefs.getBoolean("vib_a", true); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sMax"; text = L.max_v; textSize = "16sp"; checked = _G.prefs.getBoolean("max_vol", false); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sUseLock"; text = L.use_lock; textSize = "16sp"; checked = _G.prefs.getBoolean("auto_s", false); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sAutoUsing"; text = L.auto_using; textSize = "16sp"; checked = _G.prefs.getBoolean("auto_lock_using", true); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sChgProv"; text = L.chg_p; textSize = "16sp"; checked = _G.prefs.getBoolean("chg_p_enabled", false); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sPocketProv"; text = L.pocket_p; textSize = "16sp"; checked = _G.prefs.getBoolean("pocket_p_enabled", false); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Switch; id = "sFp"; text = L.use_fp; textSize = "16sp"; checked = _G.prefs.getBoolean("fp_enabled", false); layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Button; id = "btnVerifyFp"; text = L.fp_verify; textSize = "14sp"; layout_width = "fill"; layout_marginBottom = "25dp"; visibility = _G.prefs.getBoolean("fp_enabled", false) and 0 or 8; };
      { Button; id = "btnVolChn"; text = L.vol_chn; textSize = "15sp"; layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Button; id = "btnChgLng"; text = L.chg_lng; textSize = "15sp"; layout_width = "fill"; layout_marginBottom = "10dp"; };
      { Button; id = "btnChgPwd"; text = L.chg_pwd; textSize = "15sp"; layout_width = "fill"; layout_marginBottom = "25dp"; };
      { Button; id = "btnSave"; text = L.save; textSize = "16sp"; layout_width = "fill"; backgroundColor = 0xFF4CAF50; };
    };
  }
  local views = {}
  settingsDialog.setView(loadlayout(layout, views))
  views.sCustomSnd.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener({onCheckedChanged = function(b, c) _G.prefs.edit().putBoolean("use_custom_snd", c).commit() views.btnSelectSound.setVisibility(c and 0 or 8) end}))
  views.btnSelectSound.setOnClickListener(function() openFilePicker() end)
  views.sAutoUsing.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener({onCheckedChanged = function(b, c) _G.prefs.edit().putBoolean("auto_lock_using", c).commit() if c then openInactivityTimerSelector() else cancelIdleTimer() end end}))

  views.sFp.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener({
    onCheckedChanged = function(buttonView, isChecked)
      if isChecked then
        views.btnVerifyFp.setVisibility(0)
        bgSpeak("Touch sensor now to save")
        _G.verifyFingerprint(true, function()
          _G.prefs.edit().putBoolean("fp_enabled", true).putBoolean("fp_verified", true).commit()
        end, function()
          views.sFp.setChecked(false)
          views.btnVerifyFp.setVisibility(8)
          _G.prefs.edit().putBoolean("fp_enabled", false).commit()
        end)
      else
        views.btnVerifyFp.setVisibility(8)
        _G.prefs.edit().putBoolean("fp_enabled", false).putBoolean("fp_verified", false).commit()
        pcall(function() if _G.currentFpPrompt ~= nil then _G.currentFpPrompt.cancelAuthentication() end end)
        bgSpeak("Fingerprint disabled")
      end
    end
  }))

  views.btnVerifyFp.setOnClickListener(function()
    _G.verifyFingerprint(true, function() bgSpeak("Fingerprint saved again") end, function() end)
  end)

  views.btnVolChn.setOnClickListener(function() openChannelSelector() end)
  views.btnChgLng.setOnClickListener(function() _G.showLanguageSelect(true) end)
  views.btnChgPwd.setOnClickListener(function() _G.showPIN(true) end)
  views.btnSave.setOnClickListener(function()
    _G.prefs.edit().putBoolean("snd_a", views.sSnd.isChecked()).putBoolean("use_custom_snd", views.sCustomSnd.isChecked()).putBoolean("vib_a", views.sVib.isChecked()).putBoolean("max_vol", views.sMax.isChecked()).putBoolean("auto_s", views.sUseLock.isChecked()).putBoolean("auto_lock_using", views.sAutoUsing.isChecked()).putBoolean("chg_p_enabled", views.sChgProv.isChecked()).putBoolean("pocket_p_enabled", views.sPocketProv.isChecked()).putBoolean("fp_enabled", views.sFp.isChecked()).commit()
    if not views.sFp.isChecked() then pcall(function() if _G.currentFpPrompt ~= nil then _G.currentFpPrompt.cancelAuthentication() end end) end
    if _G.prefs.getBoolean("fp_enabled", false) and not _G.prefs.getBoolean("fp_verified", false) then
      bgSpeak("Please verify fingerprint first")
      _G.verifyFingerprint(true, function()
        _G.prefs.edit().putBoolean("fp_verified", true).commit()
        if views.sPocketProv.isChecked() then _G.startPocketWatcher() else _G.stopPocketWatcher() end
        clearUiState() _G.showMainUI()
      end, function() end)
      return
    end
    if views.sPocketProv.isChecked() then _G.startPocketWatcher() else _G.stopPocketWatcher() end
    clearUiState() _G.showMainUI()
  end)
  applyOverlayFlags(settingsDialog)
  settingsDialog.show()
end

_G.showMainUI = function()
  local L = getL()
  local mainDialog = createManagedDialog("MAIN")
  if mainDialog == nil then return true end
  mainDialog.setTitle(L.title)
  local layout = {
    LinearLayout; orientation = "vertical"; padding = "30dp";
    { Button; id = "btnMainSets"; text = L.sets; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "10dp"; };
    { Button; id = "btnMainAb"; text = L.ab; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "15dp"; };
    { Switch; id = "sw"; text = L.use_sp; textSize = "16sp"; checked = _G.isSecEnabled; layout_width = "fill"; layout_marginBottom = "25dp"; };
    { Button; id = "btnMainEx"; text = L.ex; textSize = "16sp"; layout_width = "fill"; backgroundColor = 0xFFF44336; };
  }
  local views = {}
  local view = loadlayout(layout, views)
  views.btnMainSets.setOnClickListener(function() _G.resetUserActivity(); openSettings() end)
  views.btnMainAb.setOnClickListener(function() _G.resetUserActivity(); openAboutApp() end)
  views.btnMainEx.setOnClickListener(function()
    cancelIdleTimer()
    clearUiState()
    pcall(function() if _G.currentFpPrompt ~= nil then _G.currentFpPrompt.cancelAuthentication() _G.currentFpPrompt = nil end end)
    if _G.prefs.getBoolean("pocket_p_enabled", false) then
      _G.isSecEnabled = false
      _G.isPocketActive = false
      playAlert(false)
      releaseWake()
      _G.startPocketWatcher()
      bgSpeak("Closed - Pocket mode still watching")
    else
      bgSpeak("The Smart Protector is closed")
      _G.stopPocketWatcher()
      _G.isSecEnabled = false
      playAlert(false)
      releaseWake()
    end
  end)
  views.sw.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener({onCheckedChanged = function(button, isChecked) _G.resetUserActivity() _G.toggleSec(isChecked, false) end}))
  mainDialog.setView(view)
  applyOverlayFlags(mainDialog)
  mainDialog.show()
  return true
end

pcall(function() if _G.G_FP then service.unregisterReceiver(_G.G_FP); _G.G_FP = nil end end)
_G.G_FP = LuaBroadcastReceiver(function(context, intent)
  if intent == nil then return true end
  local action = intent.getAction()
  local L = getL()
  if action == Intent.ACTION_SCREEN_OFF then
    cancelIdleTimer()
    if _G.prefs.getBoolean("auto_s", false) or _G.isSecEnabled then acquireWake() bgSpeak(L.s_en) mainHandler.postDelayed(Runnable({run = function() _G.toggleSec(true, true) end}), 450) end
  elseif action == Intent.ACTION_USER_PRESENT then
    if _G.isSecEnabled or _G.prefs.getBoolean("auto_s", false) then _G.showPIN(false) else startIdleTimer() end
  elseif action == Intent.ACTION_POWER_CONNECTED then
    if _G.prefs.getBoolean("chg_p_enabled", false) then _G.isChargingActive = true acquireWake() bgSpeak(L.chg_en) end
  elseif action == Intent.ACTION_POWER_DISCONNECTED then
    if _G.prefs.getBoolean("chg_p_enabled", false) and _G.isChargingActive then _G.currentReason = "charging" acquireWake() playAlert(true) _G.showPIN(false) end
  end
  return true
end)
local filter = IntentFilter()
filter.addAction(Intent.ACTION_SCREEN_OFF)
filter.addAction(Intent.ACTION_USER_PRESENT)
filter.addAction(Intent.ACTION_POWER_CONNECTED)
filter.addAction(Intent.ACTION_POWER_DISCONNECTED)
filter.setPriority(1000)
service.registerReceiver(_G.G_FP, filter)

_G.boot = function()
  initTts(function() bgSpeak("Welcome to Smart Protector.") end)
  if not _G.prefs.getBoolean("master_reset_done_v41", false) then
    _G.prefs.edit()
.putBoolean("snd_a", true).putBoolean("use_custom_snd", false).putString("custom_sound_path", "")
.putBoolean("vib_a", true).putBoolean("max_vol", false).putBoolean("auto_s", false)
.putBoolean("auto_lock_using", true).putInt("inactivity_interval", 60000)
.putBoolean("chg_p_enabled", false).putBoolean("pocket_p_enabled", false).putInt("pocket_light_threshold", 15)
.putBoolean("fp_enabled", false).putBoolean("fp_verified", false)
.putBoolean("first_run_done", false).putBoolean("master_reset_done_v41", true).commit()
  end
  if not _G.prefs.getBoolean("first_run_done", false) then _G.showLanguageSelect(false)
  else _G.showMainUI() startIdleTimer() _G.startPocketWatcher() end
  return true
end
_G.boot()

require "import" import "com.androlua.Http" import "com.androlua.LuaDialog" import "android.widget.Toast" import "android.os.Handler" import "android.os.Looper" import "java.lang.Thread" import "java.lang.Runnable" import "java.lang.System" import "java.io.File" import "android.content.Context" import "android.media.ToneGenerator" import "android.media.AudioManager" import "android.os.Vibrator" import "android.os.Build" import "android.os.VibrationEffect"  local CURRENT_VERSION = "3.0" local VERSION_URL = "https://raw.githubusercontent.com/muhammadmohsinraza12346712467-eng/Smart-protector/main/Smart%20protector./Virgin.txt" local UPDATE_CODE_URL = "https://raw.githubusercontent.com/muhammadmohsinraza12346712467-eng/Smart-protector/main/Smart%20protector./Main.lua" local PLUGIN_PATH = (function()     local src = debug.getinfo(1, "S").source     return src and src:match("^@?(.*)$") or "" end)() local updateInProgress = false  local prefs = (service or activity).getSharedPreferences("AutoUpdatePrefs", Context.MODE_PRIVATE)   local function trim(s)     if s == nil then return "" end     return tostring(s):gsub("^%s*(.-)%s*$", "%1") end  local function showUpdateErrorDialog(title, message)     Handler(Looper.getMainLooper()).post(Runnable({         run = function()             local errorDialog = LuaDialog(service or activity)             errorDialog.setTitle(title)             errorDialog.setMessage(message)             errorDialog.setButton("OK", function()                 errorDialog.dismiss()             end)             errorDialog.show()         end     })) end  local function checkAndShowNewFeatures()     -- No new features provided end  local function performUpdate(mainCode, onlineVersion)     if not mainCode or trim(mainCode) == "" then         showUpdateErrorDialog("Update Failed", "Main plugin code is empty.")         return     end          updateInProgress = true          local function updateProcess()         local currentFileSrc = debug.getinfo(1, "S").source         local currentFilePath = currentFileSrc and currentFileSrc:match("^@?(.*)$") or ""                  if currentFilePath ~= "" and currentFilePath ~= PLUGIN_PATH then             pcall(function()                 os.rename(currentFilePath, PLUGIN_PATH)             end)         end                  local success = false         local tempPath = PLUGIN_PATH .. ".temp_update"         local f = io.open(tempPath, "w")         if f then             f:write(mainCode)             f:close()                          local fileExists = io.open(PLUGIN_PATH, "r")             if fileExists then                 fileExists:close()                 local delSuccess = pcall(function()                     os.remove(PLUGIN_PATH)                 end)                 if delSuccess then                     local renameSuccess = pcall(function()                         os.rename(tempPath, PLUGIN_PATH)                     end)                     if renameSuccess then                         success = true                     end                 end             else                 local renameSuccess = pcall(function()                     os.rename(tempPath, PLUGIN_PATH)                 end)                 if renameSuccess then                     success = true                 end             end                          if not success then                 pcall(function() os.remove(tempPath) end)             end         end                  if success then             updateInProgress = false             Handler(Looper.getMainLooper()).post(Runnable({                 run = function()                                         local successDialog = LuaDialog(service or activity)                     successDialog.setTitle("Update Successful")                     successDialog.setMessage("Successfully updated to the latest version.\n\nClick OK to restart and apply the update.")                     successDialog.setButton("OK", function()                         successDialog.dismiss()                                                  Handler(Looper.getMainLooper()).post(Runnable({                             run = function()                                 pcall(function() if _G.mainDialog then _G.mainDialog.dismiss() _G.mainDialog = nil end end)                                 pcall(function() if _G.mainDlg then _G.mainDlg.dismiss() _G.mainDlg = nil end end)                                 pcall(function() if _G.allDialogBox then _G.allDialogBox.dismiss() _G.allDialogBox = nil end end)                                 pcall(function() if _G.alertDialogBox then _G.alertDialogBox.dismiss() _G.alertDialogBox = nil end end)                                                                  pcall(function() if _G.dismissAllDialogs then _G.dismissAllDialogs() end end)                                 pcall(function() if _G.dismissAll then _G.dismissAll() end end)                                 pcall(function() if _G.dismiss then _G.dismiss() end end)                                 pcall(function() if dismissAllDialogs then dismissAllDialogs() end end)                                 pcall(function() if dismissAll then dismissAll() end end)                                  pcall(function()                                     if activity then                                         activity.finish()                                     end                                 end)                             end                         }))                                                  Handler(Looper.getMainLooper()).postDelayed(Runnable({                             run = function()                                 prefs.edit().putString("lastShownVersion", "").apply()                                 local pluginFile = io.open(PLUGIN_PATH, "r")                                 if pluginFile then                                     pluginFile:close()                                     local func, err = loadfile(PLUGIN_PATH)                                     if func then                                         pcall(func)                                     else                                         Toast.makeText(service or activity, "Error reloading plugin: " .. tostring(err), Toast.LENGTH_SHORT).show()                                     end                                 end                             end                         }), 2000)                     end)                     successDialog.show()                 end             }))             return         else             updateInProgress = false             showUpdateErrorDialog("Update Failed", "Update failed. Please try again.")         end     end          local updateThread = Thread(Runnable{         run = updateProcess     })     updateThread.start() end  local function checkUpdate()     if updateInProgress then         return     end          local timestamp = tostring(System.currentTimeMillis())     Http.get(VERSION_URL .. "?t=" .. timestamp, function(code, response)         if code == 200 and response then             local onlineVersion = trim(response)             if onlineVersion ~= CURRENT_VERSION then                 Http.get(UPDATE_CODE_URL .. "?t=" .. timestamp, function(code2, mainCode)                     if code2 == 200 and mainCode and trim(mainCode) ~= "" then                         Handler(Looper.getMainLooper()).post(Runnable({                             run = function()                                                                 local updateAlertDlg = LuaDialog(service or activity)                                 updateAlertDlg.setTitle("Update Available!")                                 updateAlertDlg.setMessage("A new version (" .. onlineVersion .. ") is available.\nCurrent version: " .. CURRENT_VERSION .. "\n\nWould you like to update now?")                                 updateAlertDlg.setButton("Update Now", function()                                     updateAlertDlg.dismiss()                                     Toast.makeText(service or activity, "Downloading update...", Toast.LENGTH_SHORT).show()                                     performUpdate(mainCode, onlineVersion)                                 end)                                 updateAlertDlg.setButton2("Later", function()                                     updateAlertDlg.dismiss()                                 end)                                 updateAlertDlg.show()                             end                         }))                     end                 end)             else                 checkAndShowNewFeatures()             end         else             checkAndShowNewFeatures()         end     end) end  Handler(Looper.getMainLooper()).postDelayed(Runnable({     run = function()         checkUpdate()     end }), 3000) 