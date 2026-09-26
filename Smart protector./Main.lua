require "import"
import "android.widget.*"
import "android.view.*"
import "android.app.*"
import "android.content.*"
import "android.os.*"
import "android.speech.tts.*"
import "android.content.Intent"
import "android.os.StatFs"
import "android.os.Environment"
import "android.os.BatteryManager"
import "java.net.URL"
import "java.net.URLEncoder"
import "java.io.*"

_G.prefs = service.getSharedPreferences("SMART_TECH_STUDIO_PREFS", 0)
local mainHandler = Handler(Looper.getMainLooper())
_G.currentUiState = "NONE" 
local globalDialog = nil
local ttsEngine = nil
local isTtsReady = false

function bgSpeak(text)
  mainHandler.post(Runnable({run = function()
    if ttsEngine ~= nil and isTtsReady then
      pcall(function() ttsEngine.speak(text, TextToSpeech.QUEUE_FLUSH, nil, "SmartTechTTS") end)
    end
  end}))
end

function initTts(onReadyCallback)
  pcall(function()
    local listener = TextToSpeech.OnInitListener({onInit = function(status)
      if status == TextToSpeech.SUCCESS then isTtsReady = true; ttsEngine.setLanguage(Locale.ENGLISH); if onReadyCallback then onReadyCallback() end end
    end})
    ttsEngine = TextToSpeech(service, listener)
  end)
end

function clearUiState()
  if globalDialog ~= nil then pcall(function() globalDialog.dismiss() end); globalDialog = nil end
  _G.currentUiState = "NONE"
end

function createManagedDialog(stateName)
  if _G.currentUiState == stateName and globalDialog ~= nil then return nil end
  clearUiState(); _G.currentUiState = stateName
  globalDialog = LuaDialog(service); globalDialog.setCancelable(true)
  return globalDialog
end

function applyOverlayFlags(dlg)
  local window = dlg.getWindow()
  window.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
  window.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
end

-- FIXED FREE AI - No Budget Error - Uses Llama 3.1 (Free)
function callFreeAI(question, callback)
  task(100, function()
    local answer = nil

    -- Try 1: Llama model (Free, Unlimited, No Budget)
    pcall(function()
      local safeQ = URLEncoder.encode(question, "UTF-8")
      local aiUrl = "https://text.pollinations.ai/"..safeQ.."?model=llama"
      local conn = URL(aiUrl).openConnection()
      conn.setRequestMethod("GET")
      conn.setConnectTimeout(15000)
      conn.setReadTimeout(20000)
      conn.setRequestProperty("User-Agent", "Mozilla/5.0")
      if conn.getResponseCode() == 200 then
        local reader = BufferedReader(InputStreamReader(conn.getInputStream()))
        local response = ""; local line = reader.readLine()
        while line ~= nil do response = response .. line .. "\n"; line = reader.readLine() end
        reader.close()
        if response ~= nil and string.len(response) > 10 then
          if not string.find(string.lower(response), "budget") then
            answer = response
          end
        end
      end
    end)

    -- Try 2: Mistral model (if first fails)
    if answer == nil then
      pcall(function()
        local safeQ = URLEncoder.encode(question, "UTF-8")
        local aiUrl = "https://text.pollinations.ai/"..safeQ.."?model=mistral"
        local conn = URL(aiUrl).openConnection()
        conn.setRequestMethod("GET")
        conn.setConnectTimeout(15000)
        local reader = BufferedReader(InputStreamReader(conn.getInputStream()))
        local response = ""; local line = reader.readLine()
        while line ~= nil do response = response .. line .. "\n"; line = reader.readLine() end
        reader.close()
        if response ~= nil and string.len(response) > 10 then answer = response end
      end)
    end

    if answer == nil then answer = "Internet error. Please check internet and try again." end
    answer = string.sub(answer, 1, 1000)
    mainHandler.post(Runnable({run=function() callback(answer) end}))
  end)
end

function openAiChat()
  local dlg = createManagedDialog("AI_CHAT")
  if dlg == nil then return end
  dlg.setTitle("Chat with AI - Free")
  bgSpeak("Type your question and press Ask AI")
  local lay = LinearLayout(service); lay.setOrientation(1); lay.setPadding(30,30,30,30)
  local edtQuestion = EditText(service); edtQuestion.setHint("Type: What is Pakistan?"); edtQuestion.setTextSize(16)
  local btnSearch = Button(service); btnSearch.setText("Ask AI")
  local scroll = ScrollView(service)
  local txtAnswer = TextView(service); txtAnswer.setText("Answer will appear here"); txtAnswer.setTextSize(16); txtAnswer.setPadding(10,20,10,10)
  scroll.addView(txtAnswer)
  lay.addView(edtQuestion); lay.addView(btnSearch); lay.addView(scroll)
  dlg.setView(lay); applyOverlayFlags(dlg); dlg.show()
  btnSearch.setOnClickListener{onClick=function()
    local question = edtQuestion.getText().toString()
    if question == "" then bgSpeak("Please type a question"); return end
    txtAnswer.setText("Asking AI: " .. question .. "\nPlease wait 5 seconds...")
    bgSpeak("Asking AI for " .. question)
    callFreeAI(question, function(answer)
      txtAnswer.setText("Q: " .. question .. "\n\nAI: " .. answer)
      bgSpeak(answer)
    end)
  end}
end

function openAbout() local msg = "Smart Tech Studio version 2.0. Free AI by Pollinations Llama."; bgSpeak(msg); local dlg = createManagedDialog("ABOUT"); dlg.setTitle("About"); local txt = TextView(service).setText(msg).setTextSize(18).setPadding(30,30,30,30); dlg.setView(txt); applyOverlayFlags(dlg); dlg.show(); mainHandler.postDelayed(Runnable({run=function() clearUiState(); showMainUI() end}), 4000) end
function openHowToUse() local msg = "Tap Chat with AI. Type any question. Press Ask AI. It will speak the answer."; bgSpeak(msg); local dlg = createManagedDialog("HOW"); dlg.setTitle("How to Use"); local txt = TextView(service).setText(msg).setTextSize(18).setPadding(30,30,30,30); dlg.setView(txt); applyOverlayFlags(dlg); dlg.show(); mainHandler.postDelayed(Runnable({run=function() clearUiState(); showMainUI() end}), 5000) end
function openPhoneInfo() local bat = service.registerReceiver(nil, IntentFilter(Intent.ACTION_BATTERY_CHANGED)); local level = bat.getIntExtra(BatteryManager.EXTRA_LEVEL, -1); local scale = bat.getIntExtra(BatteryManager.EXTRA_SCALE, -1); local batteryPct = math.floor(level * 100 / scale); local stat = StatFs(Environment.getExternalStorageDirectory().getPath()); local freeGB = math.floor(stat.getAvailableBytes() / 1073741824); local msg = "Battery " .. batteryPct .. " percent. Free storage " .. freeGB .. " GB."; bgSpeak(msg); local dlg = createManagedDialog("PHONE"); dlg.setTitle("Phone Information"); local txt = TextView(service).setText(msg).setTextSize(18).setPadding(30,30,30,30); dlg.setView(txt); applyOverlayFlags(dlg); dlg.show(); mainHandler.postDelayed(Runnable({run=function() clearUiState(); showMainUI() end}), 4000) end
function showMainUI() local dlg = createManagedDialog("MAIN"); if dlg == nil then return true end; dlg.setTitle("Smart Tech Studio"); local layout = {LinearLayout; orientation = "vertical"; padding = "30dp"; gravity = "center"; { TextView; text = "Smart Tech Studio"; textSize = "22sp"; textColor = 0xFF4CAF50; layout_marginBottom = "25dp"; }; { Button; id = "btnAbout"; text = "About"; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "15dp"; }; { Button; id = "btnHow"; text = "How to Use"; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "15dp"; }; { Button; id = "btnAI"; text = "Chat with AI"; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "15dp"; }; { Button; id = "btnPhone"; text = "Phone Information"; textSize = "16sp"; layout_width = "fill"; layout_marginBottom = "15dp"; }; { Button; id = "btnExit"; text = "Exit"; textSize = "16sp"; layout_width = "fill"; backgroundColor = 0xFFF44336; };}; local views = {}; dlg.setView(loadlayout(layout, views)); views.btnAbout.setOnClickListener{onClick=function() openAbout() end}; views.btnHow.setOnClickListener{onClick=function() openHowToUse() end}; views.btnAI.setOnClickListener{onClick=function() openAiChat() end}; views.btnPhone.setOnClickListener{onClick=function() openPhoneInfo() end}; views.btnExit.setOnClickListener{onClick=function() bgSpeak("Closed"); clearUiState() end}; applyOverlayFlags(dlg); dlg.show(); return true end
function boot() initTts(function() bgSpeak("Welcome to Smart Tech Studio") end); showMainUI(); return true end
boot()