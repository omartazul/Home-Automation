// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam
//
// ESP-01S WiFi-to-serial bridge for ATmega8A home automation.
//
// Design intent:
// - ATmega8A firmware is flashed once and then treated as fixed.
// - ESP-01S handles all ongoing API, provisioning, and OTA work.

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <WebSocketsServer.h>
#include <EEPROM.h>
#include <Updater.h>
#include <ctype.h>
#include <ArduinoJson.h>

// Section: Build constants.
const char* kBridgeVersion = "ESP-BRIDGE-1.0.0";
const char* kMdnsName = "homeauto";
const char* kEepromCredMagic = "HOME";
const char* kEepromStateMagic = "STAT";
const char* kEepromNameMagic = "NAME";
const char* kApiUsername = "home";
const char* kDefaultPassword = "123456789";

const uint32_t kAppSerialBaud = 115200;
const unsigned long kSerialDefaultTimeoutMs = 100UL;
const unsigned long kStaConnectTimeoutMs = 15000UL;
const unsigned long kRestartDelayMs = 1000UL;

const uint16_t kSerialLineLimit = 256;
const uint8_t kNameMinLen = 3;
const uint8_t kNameMaxLen = 24;

// Section: Pins.
const uint8_t LED_PIN = 2;        // GPIO2, active LOW

// Section: EEPROM layout.
const int EEPROM_SIZE = 512;

// EEPROM memory layout struct for portable offset calculations
struct EepromLayout {
  char credMagic[4];       // offset 0, size 4
  char ssid[64];           // offset 4, size 64
  char pass[64];           // offset 68, size 64
  char stateMagic[4];      // offset 132, size 4
  uint8_t stateData[7];    // offset 136, size 7 (pwr, fan, spd, lt1, lt2, plg, minp)
  char nameMagic[4];       // offset 144, size 4
  char name[32];           // offset 148, size 32
};

#define EEPROM_MAGIC_ADDR      offsetof(EepromLayout, credMagic)
#define EEPROM_SSID_ADDR       offsetof(EepromLayout, ssid)
#define EEPROM_PASS_ADDR       offsetof(EepromLayout, pass)
#define EEPROM_STATE_MAGIC_ADDR offsetof(EepromLayout, stateMagic)
#define EEPROM_STATE_DATA_ADDR  offsetof(EepromLayout, stateData)
#define EEPROM_NAME_MAGIC_ADDR  offsetof(EepromLayout, nameMagic)
#define EEPROM_NAME_ADDR        offsetof(EepromLayout, name)

// Section: State models.
struct DeviceState {
  bool pwr;
  bool fan;
  int spd;
  bool lt1;
  bool lt2;
  bool plg;
  int minp;
  String mcu_fw;
};

ESP8266WebServer server(80);
WebSocketsServer webSocket(81);

bool apMode = true;
String serialBuffer;
String apSSID;
String staSSID;
String staPass;
String deviceName;

DeviceState state = { false, false, 1, false, false, false, 5, "" };

// EEPROM write debouncing
bool stateDirty = false;
unsigned long lastStateChangeMs = 0;

bool isSolicitedStatus = false;
unsigned long pendingGetStatusTime = 0;
bool pendingGetStatus = false;

// Section: Forward declarations.
void setupAP();
void setupSTA();
void setupRoutes();
void addCorsHeaders();

void handleNotFound();
void handleRoot();
void handleWifiScan();
void handleWifiConfig();
void handleInfo();
void handleDeviceName();
void handleCommand();
void handleStatus();
void handleFactoryReset();
void handleUpdateUpload();

void clearEEPROM();
bool loadCredentials();
void saveCredentials(const String& ssid, const String& pass);
void loadDeviceName();
void saveDeviceName(const String& name);
String defaultDeviceName();
String sanitizeDeviceName(const String& value);
String hostFriendlyName(const String& name);

void loadDeviceState();
void saveDeviceState();
void updateStateFromResponse(const String& response);
void broadcastStatus();
void webSocketEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length);

void setBridgeSerialBaud(uint32_t baud);
String sendSerialCommand(const String& cmd, unsigned long timeoutMs = kSerialDefaultTimeoutMs);
String sendSerialCommandPreferPrefix(const String& cmd, const String& preferredPrefix,
                                     unsigned long timeoutMs = kSerialDefaultTimeoutMs);

String htmlPage(const String& title, const String& body);
String jsonEscape(const String& value);
String jsonExtractString(const String& body, const String& key);
void sendJson(int code, const String& payload);

// Section: Setup and main loop.
void setup() {
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);

  setBridgeSerialBaud(kAppSerialBaud);
  serialBuffer.reserve(kSerialLineLimit);
  delay(100);

  EEPROM.begin(EEPROM_SIZE);

  loadDeviceName();
  if (loadCredentials()) {
    apMode = false;
    setupSTA();
  } else {
    apMode = true;
    setupAP();
  }

  loadDeviceState();
  isSolicitedStatus = true;
  updateStateFromResponse(sendSerialCommandPreferPrefix("GET:STATUS", "STATUS:", kSerialDefaultTimeoutMs));
  isSolicitedStatus = false;

  if (MDNS.begin(kMdnsName)) {
    MDNS.addService("http", "tcp", 80);
  }

  server.collectHeaders("Origin");

  setupRoutes();
  server.begin();
  webSocket.begin();
  webSocket.onEvent(webSocketEvent);

  for (int i = 0; i < 3; ++i) {
    digitalWrite(LED_PIN, LOW);
    delay(100);
    digitalWrite(LED_PIN, HIGH);
    delay(100);
  }
}

void loop() {
  server.handleClient();
  webSocket.loop();
  MDNS.update();

  if (pendingGetStatus && millis() >= pendingGetStatusTime) {
    pendingGetStatus = false;
    isSolicitedStatus = true;
    String syncResp = sendSerialCommandPreferPrefix("GET:STATUS", "STATUS:", kSerialDefaultTimeoutMs);
    if (syncResp.length() > 0) {
      updateStateFromResponse(syncResp);
    }
    isSolicitedStatus = false;
  }

  // Debounce EEPROM writes: save if dirty and 5 minutes have passed
  if (stateDirty && (millis() - lastStateChangeMs) >= 300000UL) {
    saveDeviceState();
    stateDirty = false;
  }

  // Keep draining UART so AVR status lines stay fresh.
  uint16_t charCount = 0;
  while (Serial.available() && charCount < 256) {
    const char c = (char)Serial.read();
    charCount++;
    if (c == '\n') {
      serialBuffer.trim();
      if (serialBuffer.length() > 0) {
        updateStateFromResponse(serialBuffer);
      }
      serialBuffer = "";
    } else if (c != '\r') {
      serialBuffer += c;
      if (serialBuffer.length() > kSerialLineLimit) {
        serialBuffer = "";
      }
    }
    yield();
  }
}

// Section: Wi-Fi setup.
void setupAP() {
  apSSID = deviceName;
  WiFi.mode(WIFI_AP);
  WiFi.softAP(apSSID.c_str(), kDefaultPassword);
  delay(200);
  apMode = true;
}

void setupSTA() {
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.mode(WIFI_STA);
  WiFi.hostname(hostFriendlyName(deviceName));
  WiFi.begin(staSSID.c_str(), staPass.c_str());

  const unsigned long startMs = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - startMs) < kStaConnectTimeoutMs) {
    delay(250);
    digitalWrite(LED_PIN, !digitalRead(LED_PIN));
  }

  if (WiFi.status() == WL_CONNECTED) {
    apMode = false;
    digitalWrite(LED_PIN, LOW);
  } else {
    setupAP();
  }
}

// Section: EEPROM helpers.
bool loadCredentials() {
  char magic[5] = { 0 };
  for (int i = 0; i < 4; ++i) {
    magic[i] = (char)EEPROM.read(EEPROM_MAGIC_ADDR + i);
  }
  if (String(magic) != kEepromCredMagic) {
    return false;
  }

  char ssid[65] = { 0 };
  char pass[65] = { 0 };
  for (int i = 0; i < 64; ++i) {
    ssid[i] = (char)EEPROM.read(EEPROM_SSID_ADDR + i);
    pass[i] = (char)EEPROM.read(EEPROM_PASS_ADDR + i);
  }

  staSSID = String(ssid);
  staPass = String(pass);
  return staSSID.length() > 0;
}

void saveCredentials(const String& ssid, const String& pass) {
  for (int i = 0; i < 4; ++i) {
    EEPROM.write(EEPROM_MAGIC_ADDR + i, kEepromCredMagic[i]);
  }
  for (int i = 0; i < 64; ++i) {
    EEPROM.write(EEPROM_SSID_ADDR + i, i < (int)ssid.length() ? ssid[i] : 0);
    EEPROM.write(EEPROM_PASS_ADDR + i, i < (int)pass.length() ? pass[i] : 0);
  }
  EEPROM.commit();
}

void clearEEPROM() {
  for (int i = 0; i < EEPROM_SIZE; ++i) {
    EEPROM.write(i, 0xFF);
  }
  EEPROM.commit();
}

String defaultDeviceName() {
  return "HomeAuto_" + String(ESP.getChipId() & 0xFFFF, HEX);
}

String sanitizeDeviceName(const String& value) {
  String out;
  String src = value;
  src.trim();

  for (int i = 0; i < (int)src.length(); ++i) {
    const char c = src[i];
    if (isAlphaNumeric(c) || c == ' ' || c == '.' || c == ',' || c == '!' || c == '@' || c == '#' ||
        c == '%' || c == '&' || c == '(' || c == ')' || c == '-' || c == '+' || c == '=' || c == '_' || c == '\'') {
      out += c;
    }
    if (out.length() >= kNameMaxLen) {
      break;
    }
  }

  if (out.length() < kNameMinLen) {
    out = defaultDeviceName();
  }
  return out;
}

String hostFriendlyName(const String& name) {
  String out;
  for (int i = 0; i < (int)name.length(); ++i) {
    const char c = name[i];
    if (isAlphaNumeric(c)) {
      out += (char)tolower(c);
    } else if ((c == ' ' || ispunct((unsigned char)c)) && out.length() > 0 && out[out.length() - 1] != '-') {
      out += '-';
    }
  }
  if (out.length() > 0 && out[out.length() - 1] == '-') {
    out.remove(out.length() - 1);
  }
  return out;
}

void loadDeviceName() {
  char magic[5] = { 0 };
  for (int i = 0; i < 4; ++i) {
    magic[i] = (char)EEPROM.read(EEPROM_NAME_MAGIC_ADDR + i);
  }

  if (String(magic) != kEepromNameMagic) {
    deviceName = defaultDeviceName();
    saveDeviceName(deviceName);
    return;
  }

  char raw[33] = { 0 };
  for (int i = 0; i < 32; ++i) {
    raw[i] = (char)EEPROM.read(EEPROM_NAME_ADDR + i);
  }

  deviceName = sanitizeDeviceName(String(raw));
  if (deviceName.length() < kNameMinLen) {
    deviceName = defaultDeviceName();
    saveDeviceName(deviceName);
  }
}

void saveDeviceName(const String& name) {
  const String safe = sanitizeDeviceName(name);
  for (int i = 0; i < 4; ++i) {
    EEPROM.write(EEPROM_NAME_MAGIC_ADDR + i, kEepromNameMagic[i]);
  }
  for (int i = 0; i < 32; ++i) {
    EEPROM.write(EEPROM_NAME_ADDR + i, i < (int)safe.length() ? safe[i] : 0);
  }
  EEPROM.commit();
  deviceName = safe;
}

// Section: Serial bridge.
void setBridgeSerialBaud(uint32_t baud) {
  Serial.flush();
  Serial.end();
  delay(2);
  Serial.begin(baud);
  Serial.setTimeout(kSerialDefaultTimeoutMs);
  delay(2);
}

String sendSerialCommand(const String& cmd, unsigned long timeoutMs) {
  serialBuffer = "";
  while (Serial.available()) {
    Serial.read();
  }

  Serial.print(cmd);
  if (!cmd.endsWith("\n")) {
    Serial.print('\n');
  }
  Serial.flush();

  String response;
  response.reserve(256);
  unsigned long startMs = millis();
  while ((millis() - startMs) < timeoutMs) {
    while (Serial.available()) {
      const char c = (char)Serial.read();
      response += c;
      if (c == '\n' && response.length() > 1) {
        response.trim();
        return response;
      }
    }
    yield();
  }

  response.trim();
  return response;
}

String sendSerialCommandPreferPrefix(const String& cmd, const String& preferredPrefix, unsigned long timeoutMs) {
  serialBuffer = "";
  while (Serial.available()) {
    Serial.read();
  }

  Serial.print(cmd);
  if (!cmd.endsWith("\n")) {
    Serial.print('\n');
  }
  Serial.flush();

  String currentLine;
  String firstLine;
  String preferredLine;
  currentLine.reserve(256);
  firstLine.reserve(256);
  preferredLine.reserve(256);
  unsigned long startMs = millis();
  while ((millis() - startMs) < timeoutMs) {
    while (Serial.available()) {
      const char c = (char)Serial.read();
      if (c == '\n') {
        currentLine.trim();
        if (currentLine.length() > 0) {
          if (firstLine.length() == 0) {
            firstLine = currentLine;
          }
          if (preferredPrefix.length() > 0 && currentLine.startsWith(preferredPrefix)) {
            preferredLine = currentLine;
            return preferredLine;
          }
        }
        currentLine = "";
      } else if (c != '\r') {
        currentLine += c;
        if (currentLine.length() > kSerialLineLimit) {
          currentLine = "";
        }
      }
    }
    yield();
  }

  currentLine.trim();
  if (currentLine.length() > 0) {
    if (firstLine.length() == 0) {
      firstLine = currentLine;
    }
    if (preferredPrefix.length() > 0 && currentLine.startsWith(preferredPrefix)) {
      preferredLine = currentLine;
    }
  }

  if (preferredLine.length() > 0) {
    return preferredLine;
  }
  return firstLine;
}

// Section: Cached device state.
void loadDeviceState() {
  char magic[5] = { 0 };
  for (int i = 0; i < 4; ++i) {
    magic[i] = (char)EEPROM.read(EEPROM_STATE_MAGIC_ADDR + i);
  }

  if (String(magic) != kEepromStateMagic) {
    return;
  }

  state.pwr = EEPROM.read(EEPROM_STATE_DATA_ADDR + 0) == 1;
  state.fan = EEPROM.read(EEPROM_STATE_DATA_ADDR + 1) == 1;
  state.spd = EEPROM.read(EEPROM_STATE_DATA_ADDR + 2);
  state.lt1 = EEPROM.read(EEPROM_STATE_DATA_ADDR + 3) == 1;
  state.lt2 = EEPROM.read(EEPROM_STATE_DATA_ADDR + 4) == 1;
  state.plg = EEPROM.read(EEPROM_STATE_DATA_ADDR + 5) == 1;
  state.minp = EEPROM.read(EEPROM_STATE_DATA_ADDR + 6);

  if (state.spd < 1 || state.spd > 9) {
    state.spd = 1;
  }
  if (state.minp < 0 || state.minp > 100) {
    state.minp = 5;
  }
}

void saveDeviceState() {
  for (int i = 0; i < 4; ++i) {
    EEPROM.write(EEPROM_STATE_MAGIC_ADDR + i, kEepromStateMagic[i]);
  }

  EEPROM.write(EEPROM_STATE_DATA_ADDR + 0, state.pwr ? 1 : 0);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 1, state.fan ? 1 : 0);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 2, state.spd);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 3, state.lt1 ? 1 : 0);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 4, state.lt2 ? 1 : 0);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 5, state.plg ? 1 : 0);
  EEPROM.write(EEPROM_STATE_DATA_ADDR + 6, state.minp);
  EEPROM.commit();
}

void updateStateFromResponse(const String& response) {
  const DeviceState old = state;

  if (response.startsWith("OK:PWR:ON")) state.pwr = true;
  else if (response.startsWith("OK:PWR:OFF")) state.pwr = false;
  else if (response.startsWith("OK:FAN:ON")) state.fan = true;
  else if (response.startsWith("OK:FAN:OFF")) state.fan = false;
  else if (response.startsWith("OK:FAN:SPD:")) state.spd = response.substring(11).toInt();
  else if (response.startsWith("OK:LT1:ON")) state.lt1 = true;
  else if (response.startsWith("OK:LT1:OFF")) state.lt1 = false;
  else if (response.startsWith("OK:LT2:ON")) state.lt2 = true;
  else if (response.startsWith("OK:LT2:OFF")) state.lt2 = false;
  else if (response.startsWith("OK:PLG:ON")) state.plg = true;
  else if (response.startsWith("OK:PLG:OFF")) state.plg = false;
  else if (response.startsWith("OK:MINP:")) state.minp = response.substring(8).toInt();
  else if (response.startsWith("FIRMWARE=")) state.mcu_fw = response.substring(9);
  else if (response.startsWith("MINP=")) state.minp = response.substring(5).toInt();
  else if (response.startsWith("STATUS:")) {
    String payload = response.substring(7);
    int start = 0;
    while (start < (int)payload.length()) {
      int comma = payload.indexOf(',', start);
      if (comma < 0) {
        comma = payload.length();
      }

      const String pair = payload.substring(start, comma);
      const int eq = pair.indexOf('=');
      if (eq > 0) {
        const String key = pair.substring(0, eq);
        const String value = pair.substring(eq + 1);

        if (key == "PWR") state.pwr = (value == "ON");
        else if (key == "FAN") state.fan = (value == "ON");
        else if (key == "SPD") state.spd = value.toInt();
        else if (key == "LT1") state.lt1 = (value == "ON");
        else if (key == "LT2") state.lt2 = (value == "ON");
        else if (key == "PLG") state.plg = (value == "ON");
        else if (key == "MINP") state.minp = value.toInt();
        else if (key == "FW") state.mcu_fw = value;
      }
      start = comma + 1;
    }

    // If this was a spontaneous STATUS broadcast from the ATmega (e.g. an IR remote press),
    // the ATmega might still be counting down its 120ms debounce timer before actually committing 
    // the new fan speed. Schedule a follow-up fetch in 150ms to get the true settled state.
    if (!isSolicitedStatus) {
      pendingGetStatus = true;
      pendingGetStatusTime = millis() + 150;
    }
  }

  if (state.spd < 1 || state.spd > 9) {
    state.spd = 1;
  }
  if (state.minp < 0 || state.minp > 100) {
    state.minp = 5;
  }

  if (!state.pwr) {
    state.fan = false;
    state.lt1 = false;
    state.lt2 = false;
    state.plg = false;
  }

  if (old.pwr != state.pwr || old.fan != state.fan || old.spd != state.spd || old.lt1 != state.lt1 ||
      old.lt2 != state.lt2 || old.plg != state.plg || old.minp != state.minp) {
    stateDirty = true;
    lastStateChangeMs = millis();
    broadcastStatus(); // Push instantly via WebSocket
  }
}

// Section: WebSockets
void broadcastStatus() {
  StaticJsonDocument<512> doc;
  doc["ok"] = true;
  doc["pwr"] = state.pwr ? "ON" : "OFF";
  doc["fan"] = state.fan ? "ON" : "OFF";
  doc["spd"] = String(state.spd);
  doc["lt1"] = state.lt1 ? "ON" : "OFF";
  doc["lt2"] = state.lt2 ? "ON" : "OFF";
  doc["plg"] = state.plg ? "ON" : "OFF";
  doc["minp"] = String(state.minp);
  doc["name"] = deviceName;
  doc["mcu_fw"] = state.mcu_fw;
  doc["fw"] = String(kBridgeVersion);

  String payload;
  serializeJson(doc, payload);
  webSocket.broadcastTXT(payload);
}

void webSocketEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length) {
  if (type == WStype_CONNECTED) {
    StaticJsonDocument<512> doc;
    doc["ok"] = true;
    doc["pwr"] = state.pwr ? "ON" : "OFF";
    doc["fan"] = state.fan ? "ON" : "OFF";
    doc["spd"] = String(state.spd);
    doc["lt1"] = state.lt1 ? "ON" : "OFF";
    doc["lt2"] = state.lt2 ? "ON" : "OFF";
    doc["plg"] = state.plg ? "ON" : "OFF";
    doc["minp"] = String(state.minp);
    doc["name"] = deviceName;
    doc["mcu_fw"] = state.mcu_fw;
    doc["fw"] = String(kBridgeVersion);

    String payload;
    serializeJson(doc, payload);
    webSocket.sendTXT(num, payload);
  }
}

// Section: HTTP routes.
void setupRoutes() {
  server.onNotFound(handleNotFound);

  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/wifi/scan", HTTP_GET, handleWifiScan);
  server.on("/api/wifi", HTTP_POST, handleWifiConfig);
  server.on("/api/info", HTTP_GET, handleInfo);
  server.on("/api/device-name", HTTP_ANY, handleDeviceName);
  server.on("/api/command", HTTP_POST, handleCommand);
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/factory-reset", HTTP_POST, handleFactoryReset);

  server.on("/api/update", HTTP_POST,
    []() {
      addCorsHeaders();
      if (!server.authenticate(kApiUsername, kDefaultPassword)) {
        return server.requestAuthentication();
      }
      if (Update.hasError()) {
        sendJson(500, "{\"error\":\"OTA failed\"}");
      } else {
        sendJson(200, "{\"ok\":true,\"message\":\"OTA success. Rebooting...\"}");
      }
      delay(kRestartDelayMs);
      ESP.restart();
    },
    handleUpdateUpload);
}

void addCorsHeaders() {
  if (server.hasHeader("Origin")) {
    server.sendHeader("Access-Control-Allow-Origin", server.header("Origin"));
    server.sendHeader("Access-Control-Allow-Credentials", "true");
  } else {
    server.sendHeader("Access-Control-Allow-Origin", "null");
  }
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

void handleNotFound() {
  if (server.method() == HTTP_OPTIONS) {
    addCorsHeaders();
    server.send(204);
    return;
  }
  server.send(404, "text/plain", "Not Found");
}

// Section: API handlers.
void handleRoot() {
  String body;
  body.reserve(400);
  body += "<h2>HomeAuto WiFi Setup</h2>";
  if (apMode) {
    body += "<p>Connect to your router.</p><form method='POST' action='/api/wifi'>SSID: <input name='ssid' required><br><br>Password: <input name='pass' type='password'><br><br><button type='submit'>Connect</button></form>";
  } else {
    body += "<p>Connected to: <b>";
    body += jsonEscape(WiFi.SSID());
    body += "</b></p><p>IP: ";
    body += WiFi.localIP().toString();
    body += "</p>";
  }
  server.send(200, "text/html", htmlPage("HomeAuto", body));
}

void handleWifiScan() {
  addCorsHeaders();
  const int n = WiFi.scanNetworks();

  DynamicJsonDocument doc(4096);
  JsonArray networks = doc.to<JsonArray>();
  
  for (int i = 0; i < n; ++i) {
    JsonObject net = networks.createNestedObject();
    net["ssid"] = WiFi.SSID(i);
    net["rssi"] = WiFi.RSSI(i);
    net["open"] = (WiFi.encryptionType(i) == ENC_TYPE_NONE);
  }

  String json;
  serializeJson(doc, json);
  sendJson(200, json);
}

void handleWifiConfig() {
  addCorsHeaders();

  String ssid;
  String pass;

  if (server.hasArg("plain")) {
    const String body = server.arg("plain");
    StaticJsonDocument<512> doc;
    DeserializationError error = deserializeJson(doc, body);
    
    if (!error) {
      ssid = doc["ssid"].as<String>();
      pass = doc["pass"].as<String>();
    }
  } else {
    ssid = server.arg("ssid");
    pass = server.arg("pass");
  }

  if (ssid.length() == 0) {
    sendJson(400, "{\"error\":\"SSID required\"}");
    return;
  }

  saveCredentials(ssid, pass);
  sendJson(200, "{\"ok\":true,\"message\":\"Credentials saved. Rebooting...\"}");
  delay(kRestartDelayMs);
  ESP.restart();
}

void handleInfo() {
  addCorsHeaders();

  String ip = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  
  StaticJsonDocument<512> doc;
  doc["mode"] = apMode ? "AP" : "STA";
  doc["name"] = deviceName;
  doc["mdns"] = "homeauto.local";
  doc["ssid"] = apMode ? apSSID : WiFi.SSID();
  doc["ip"] = ip;
  doc["mac"] = WiFi.macAddress();
  doc["rssi"] = apMode ? 0 : WiFi.RSSI();
  doc["heap"] = ESP.getFreeHeap();
  doc["chipId"] = String(ESP.getChipId(), HEX);
  doc["uptime"] = millis() / 1000;

  String payload;
  serializeJson(doc, payload);
  sendJson(200, payload);
}

void handleDeviceName() {
  addCorsHeaders();

  if (server.method() == HTTP_GET) {
    StaticJsonDocument<128> doc;
    doc["ok"] = true;
    doc["name"] = deviceName;
    String json;
    serializeJson(doc, json);
    sendJson(200, json);
    return;
  }

  if (!server.hasArg("plain")) {
    sendJson(400, "{\"error\":\"Body required\"}");
    return;
  }

  StaticJsonDocument<256> doc;
  DeserializationError error = deserializeJson(doc, server.arg("plain"));
  if (error) {
    sendJson(400, "{\"error\":\"Invalid JSON\"}");
    return;
  }

  String newName = sanitizeDeviceName(doc["name"].as<String>());
  if (newName.length() < kNameMinLen) {
    sendJson(400, "{\"error\":\"Invalid name\"}");
    return;
  }

  saveDeviceName(newName);
  
  StaticJsonDocument<128> response;
  response["ok"] = true;
  response["name"] = deviceName;
  response["message"] = "Rebooting.";
  String jsonResponse;
  serializeJson(response, jsonResponse);

  sendJson(200, jsonResponse);
  delay(kRestartDelayMs);
  ESP.restart();
}

void handleCommand() {
  addCorsHeaders();

  if (!server.authenticate(kApiUsername, kDefaultPassword)) {
    return server.requestAuthentication();
  }

  if (!server.hasArg("plain")) {
    sendJson(400, "{\"error\":\"No body\"}");
    return;
  }

  StaticJsonDocument<256> reqDoc;
  DeserializationError error = deserializeJson(reqDoc, server.arg("plain"));
  if (error) {
    sendJson(400, "{\"error\":\"Invalid JSON\"}");
    return;
  }

  const String cmd = reqDoc["cmd"].as<String>();
  if (cmd.length() == 0) {
    sendJson(400, "{\"error\":\"cmd required\"}");
    return;
  }

  String cmdUpper = cmd;
  cmdUpper.toUpperCase();

  String resp = sendSerialCommand(cmd, kSerialDefaultTimeoutMs);
  isSolicitedStatus = true;
  updateStateFromResponse(resp);
  isSolicitedStatus = false;

  StaticJsonDocument<512> resDoc;
  resDoc["ok"] = true;
  resDoc["response"] = resp;
  String jsonResponse;
  serializeJson(resDoc, jsonResponse);
  
  sendJson(200, jsonResponse);
}

void handleStatus() {
  addCorsHeaders();

  StaticJsonDocument<512> doc;
  doc["ok"] = true;
  doc["pwr"] = state.pwr ? "ON" : "OFF";
  doc["fan"] = state.fan ? "ON" : "OFF";
  doc["spd"] = String(state.spd);
  doc["lt1"] = state.lt1 ? "ON" : "OFF";
  doc["lt2"] = state.lt2 ? "ON" : "OFF";
  doc["plg"] = state.plg ? "ON" : "OFF";
  doc["minp"] = String(state.minp);
  doc["name"] = deviceName;
  doc["mcu_fw"] = state.mcu_fw;
  doc["fw"] = String(kBridgeVersion);

  String payload;
  serializeJson(doc, payload);
  sendJson(200, payload);
}


void handleFactoryReset() {
  addCorsHeaders();
  if (!server.authenticate(kApiUsername, kDefaultPassword)) {
    return server.requestAuthentication();
  }
  clearEEPROM();
  sendJson(200, "{\"ok\":true,\"message\":\"Factory reset. Rebooting...\"}");
  delay(kRestartDelayMs);
  ESP.restart();
}

void handleUpdateUpload() {
  if (!server.authenticate(kApiUsername, kDefaultPassword)) {
    return;
  }

  HTTPUpload& upload = server.upload();

  if (upload.status == UPLOAD_FILE_START) {
    if (!upload.filename.endsWith(".bin")) {
      Update.printError(Serial);
      return;
    }

    const uint32_t flashSpace = (ESP.getFreeSketchSpace() - 0x1000) & 0xFFFFF000;
    if (!Update.begin(flashSpace, U_FLASH)) {
      Update.printError(Serial);
    }
  } else if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
      Update.printError(Serial);
    }
  } else if (upload.status == UPLOAD_FILE_END) {
    Update.end(true);
  }
}

// Section: Small helpers.
String jsonEscape(const String& value) {
  String out = value;
  out.replace("\\", "\\\\");
  out.replace("\"", "\\\"");
  out.replace("\n", "\\n");
  out.replace("\r", "");
  return out;
}

void sendJson(int code, const String& payload) {
  server.send(code, "application/json", payload);
}

String htmlPage(const String& title, const String& body) {
  String html;
  html.reserve(600);
  html += "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>";
  html += title;
  html += "</title><style>body{font-family:sans-serif;max-width:400px;margin:40px auto;padding:0 16px;background:#f5f5f5;}h2{color:#5B1029;}input,button{display:block;width:100%;padding:10px;margin:6px 0;box-sizing:border-box;border:1px solid #ccc;border-radius:6px;}button{background:#5B1029;color:white;border:none;cursor:pointer;font-size:16px;}button:hover{background:#7a1a3a;}</style></head><body>";
  html += body;
  html += "</body></html>";
  return html;
}
