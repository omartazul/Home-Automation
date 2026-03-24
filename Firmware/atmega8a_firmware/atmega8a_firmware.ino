// Home Automation HV3.0 firmware FV5.0.0.
// Note: HV means hardware version; FV means firmware version.
// Author: Md. Omar Faruk Tazul Islam.
// Date: March 2, 2025.
// Target: ATmega8 or ATmega8A at 16 MHz (F_CPU = 16000000UL).
// Implements appliance control with phase-angle triac firing,
// zero-cross synchronization (INT0), SIRC-12 infrared control,
// and EEPROM-backed persistent state using direct register access.

// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam
// Licensed under the Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)
// Personal, non-commercial use only. Commercial use or redistribution for sale
// is not permitted without prior written permission from the author.
// For commercial licensing requests: please open a 'Commercial license request' issue in this repository.

#include <Arduino.h>
#include <EEPROM.h>
#include <util/atomic.h>
#include <avr/pgmspace.h>
#include <avr/interrupt.h>
#include <avr/io.h>
#include <string.h>
#include <stdlib.h>

// Firmware version.
#define FIRMWARE_VERSION "FV5.1.0"

// Build-time safeguards.
#if !defined(__AVR_ATmega8__) && !defined(__AVR_ATmega8A__)
#error "This sketch only supports ATmega8 or ATmega8A targets. Build aborted."
#endif

#ifndef F_CPU
#error "F_CPU must be defined as 16000000UL in project settings."
#endif
#if (F_CPU != 16000000UL)
#error "F_CPU must be 16000000UL (16 MHz) to match timing assumptions."
#endif

// Diagnostics logging macros forward directly to Serial.
// Keep log messages compact and avoid expensive operations.
#define LOG(...) Serial.print(__VA_ARGS__)
#define LOGLN(...) Serial.println(__VA_ARGS__)
// Print strings from flash to save RAM.
#define LOGS(x) Serial.print(F(x))
#define LOGLNS(x) Serial.println(F(x))

// Section: Constants and timing.
const unsigned int GATE_PULSE_US = 200;  // Triac gate duration (us)
const unsigned int MIN_DELAY_US = 50;
const unsigned int MAX_DELAY_US = 9500;
// Timer tick at prescaler 64 and 16 MHz equals 4 us per tick.
const unsigned int TIMER_TICK_US = 4;
const unsigned int MIN_DELAY_TICKS = (MIN_DELAY_US + TIMER_TICK_US - 1) / TIMER_TICK_US;
const unsigned int MAX_DELAY_TICKS = MAX_DELAY_US / TIMER_TICK_US;
const unsigned int WATCHDOG_TIMEOUT_MS = 100;
const bool AUTO_RECOVERY_ENABLED = true;
const unsigned int AUTO_RECOVERY_DELAY_SEC = 30;
const uint8_t MAX_RECOVERY_ATTEMPTS = 3;
const bool ZC_FREQUENCY_CHECK = true;
const unsigned long SPONTANEOUS_RECOVERY_WINDOW_US = 150000UL;
const unsigned int IR_LEADER_US = 2300;
const unsigned int IR_BIT_US = 900;
const unsigned long IR_LEADER_TIMEOUT_US = 55000UL;
const unsigned long IR_BIT_TIMEOUT_US = 5000UL;
const unsigned int ZC_DEBOUNCE_US = 2000;
const unsigned int WATCHDOG_CHECK_INTERVAL_MS = 500;
const unsigned int ZC_FREQ_CHECK_INTERVAL_MS = 1000;  // changed from 2000 to 1000 (1s window)
const unsigned int ZC_FREQ_MIN = 95;
const unsigned int ZC_FREQ_MAX = 105;
const unsigned long DIAG_INTERVAL_MS = 1000UL;
// Half-cycle computation is intentionally omitted.
// This firmware uses DELAY_FROM_PERCENT for deterministic timing.
// Allowable difference between zero-cross count and triac fires before warning.
const unsigned int TRIAC_MISS_TOLERANCE = 2;
// IR command debounce in milliseconds to avoid repeated remote repeats.
const unsigned long IR_COMMAND_DEBOUNCE_MS = 120UL;
// Fan levels map as 1 = slowest and 9 = fastest.
// Level changes are applied immediately without soft ramping.

// Approximate conduction power percentage for each delay value.
const uint8_t FAN_POWER_PERCENT[9] PROGMEM = { 100, 88, 76, 64, 53, 41, 29, 17, 5 };
const uint16_t validCodes[7] PROGMEM = { 0xF01, 0xF02, 0xF03, 0xF04, 0xF05, 0xF06, 0xF07 };
// Main lookup table: percent [0..100] to delay_us.
// Values are stored in PROGMEM and clamped to MIN_DELAY_US and MAX_DELAY_US.
// The MINP CLI command adjusts the minimum conduction percent in EEPROM.
const uint16_t DELAY_FROM_PERCENT[101] PROGMEM = { 9500, 8840, 8531, 8310, 8132, 7980, 7846, 7724, 7612, 7508, 7411, 7319, 7231, 7147, 7067, 6990, 6915, 6842, 6772, 6704, 6637, 6572, 6508, 6445, 6384, 6324, 6264, 6206, 6149, 6092, 6036, 5980, 5926, 5871, 5818, 5765, 5712, 5659, 5607, 5556, 5504, 5453, 5402, 5351, 5301, 5251, 5200, 5150, 5100, 5050, 5000, 4950, 4900, 4850, 4800, 4749, 4699, 4649, 4598, 4547, 4496, 4444, 4393, 4341, 4288, 4235, 4182, 4129, 4074, 4020, 3964, 3908, 3851, 3794, 3736, 3676, 3616, 3555, 3492, 3428, 3363, 3296, 3228, 3158, 3085, 3010, 2933, 2853, 2769, 2681, 2589, 2492, 2388, 2276, 2154, 2020, 1868, 1690, 1469, 1160, 50 };

// Section: Pin assignments for ATmega8 and ATmega8A.
// Output triac gate: PD3. Zero-cross input: PD2 (INT0).
const byte fanPin = PD3;
const byte socketPin = PC5;
const byte light1Pin = PC0;
const byte light2Pin = PC1;
// Zero-cross detection uses INT0 (PD2), configured in ISR setup.
const byte irPin = PB2;  // IR receiver on PB2

// Seven-segment mapping uses discrete port bits for segments A to G.
const byte segmentAPin = PD7, segmentBPin = PB0, segmentCPin = PC2, segmentDPin = PC3, segmentEPin = PC4, segmentFPin = PD6, segmentGPin = PD5;
// segmentPorts array was removed because it was unused.
const byte segmentBitMasks[] PROGMEM = { (1 << 7), (1 << 0), (1 << 2), (1 << 3), (1 << 4), (1 << 6), (1 << 5) };

// Digit segment masks: 0-9, off, and 'F'.
const byte digitSegments[] PROGMEM = { 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F, 0x00, 0x71 };

// EEPROM addresses.
const byte power_addr = 6, fan_addr = 7, fan_lvl = 8, light1_addr = 9, light2_addr = 10, socket_addr = 11;

// EEPROM state values.
const byte STATE_OFF = 1;
const byte STATE_ON = 2;

// Section: Globals shared with ISRs.
volatile unsigned int targetDelayTicks = 0;
volatile bool fireEnabled = false;
volatile bool timerActive = false;
volatile unsigned long lastZeroCross = 0;
volatile unsigned long lastFire = 0;
volatile unsigned int zcCount = 0;
volatile unsigned long lastZC = 0;
volatile unsigned long lastZCDelta = 0;  // delta in microseconds between consecutive zero-cross events (for debug)
volatile bool triacPulseActive = false;
volatile bool zcParity = false;         // toggles every INT0 call (half-cycle parity)
volatile bool scheduledParity = false;  // parity for the currently scheduled fire
volatile unsigned int triacFiresTotal = 0;
volatile unsigned int triacFiresParity[2] = { 0, 0 };

// Reset triac counters atomically.
static inline void resetTriacCounters() {
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    triacFiresTotal = 0;
    triacFiresParity[0] = 0;
    triacFiresParity[1] = 0;
  }
}

volatile uint8_t eeprom_fan_state = STATE_OFF;
volatile uint8_t eeprom_power_state = STATE_OFF;
volatile uint8_t eeprom_light1_state = STATE_OFF;
volatile uint8_t eeprom_light2_state = STATE_OFF;
volatile uint8_t eeprom_socket_state = STATE_OFF;
volatile uint8_t eeprom_fan_level = 1;
const byte fan_min_pct_addr = 12;
volatile uint8_t eeprom_min_percent = 5;  // default 5%
// Pending fan changes are committed in the main loop to avoid spikes.
volatile byte pendingFanLevel = 0;
volatile byte pendingDisplayDigit = 0;
volatile unsigned long pendingApplyTime = 0UL;

// Software switch state flags set by IR decode or serial commands.
// Add debounce logic here if hardware buttons are introduced.
bool PowerSwState = HIGH, LastPowerSwState = HIGH;
bool FanSwState = HIGH, LastFanSwState = HIGH;
bool PlusSwState = HIGH, LastPlusSwState = HIGH;
bool MinusSwState = HIGH, LastMinusSwState = HIGH;
bool Light1SwState = HIGH, LastLight1SwState = HIGH;
bool Light2SwState = HIGH, LastLight2SwState = HIGH;
bool SocketSwState = HIGH, LastSocketSwState = HIGH;

// Diagnostics state.
// Serial-based diagnostic messages are always enabled.
unsigned long lastIRMillis = 0UL;
int lastIRCode = -1;

// Watchdog and auto-recovery helpers.
static bool wasDisabledByWatchdog = false;
static unsigned long watchdogDisableTime = 0UL;
static byte lastValidLevel = 1;
static uint8_t recoveryAttempts = 0;

// Section: Atomic access helpers.
static inline unsigned long atomicReadUL(volatile unsigned long &v) {
  unsigned long tmp;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    tmp = v;
  }
  return tmp;
}
static inline void atomicWriteUL(volatile unsigned long &v, unsigned long val) {
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    v = val;
  }
}
static inline unsigned int atomicReadUI(volatile unsigned int &v) {
  unsigned int tmp;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    tmp = v;
  }
  return tmp;
}
static inline void atomicWriteUI(volatile unsigned int &v, unsigned int val) {
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    v = val;
  }
}

// Compile-time assert to ensure expected array size.
typedef char Assert_DigitSegments[(sizeof(digitSegments) / sizeof(digitSegments[0]) >= 12) ? 1 : -1];

// Section: Function prototypes.
// Poll IR receiver and set software switch flags if a valid code is detected.
void IR_Detect();
// Return a valid SIRC-12 code or -1 if none is detected.
int getSIRC12();
// Read PB2 LOW pulse width in microseconds (blocking).
unsigned long pulseInPB2LOW(unsigned long timeout);
// Display a digit on the seven-segment display (active-LOW mapping).
void display(byte digitIndex);
// Update target delay for a requested fan level and refresh display.
void setFanDisplay(byte fanLevelEEPROM);
// Handlers for toggling power, fan, lights, and socket.
void handlePowerSwitch();
void handleFanSwitch();
void handleFanPlus();
void handleFanMinus();
// Set fan level and commit updates to EEPROM and timer state.
void setFanLevel(byte levelEEPROM, byte displayDigit);
void handleLight1Switch();
void handleLight2Switch();
void handleSocketSwitch();
// Toggle output and persist the updated state to EEPROM.
void toggleOutput(byte addr, byte pin, volatile uint8_t &port, volatile uint8_t &cachedState);

// Section: Structured command protocol (FV5.1.0).
// Line-buffered serial parser: SET:PWR:ON, SET:FAN:SPD:5, GET:STATUS, and others.
void processSerialCommand(const char *cmd);
void setPower(bool on);
void setFan(bool on);
void setFanSpeed(int level);
void setOutputExplicit(byte addr, byte pin, volatile uint8_t &port, volatile uint8_t &cachedState, bool on);
void sendStructuredStatus();

// Section: Setup and loop.
void setup() {
  // Explicitly configure hardware registers
  DDRD |= (1 << fanPin) | (1 << segmentAPin) | (1 << segmentFPin) | (1 << segmentGPin);
  DDRC |= (1 << socketPin) | (1 << light1Pin) | (1 << light2Pin) | (1 << segmentCPin) | (1 << segmentDPin) | (1 << segmentEPin);
  DDRB |= (1 << segmentBPin);

  DDRB &= ~(1 << irPin);
  PORTB |= (1 << irPin);  // Enable internal pull-up on IR receiver

  // Initialize output pins to safe off states
  PORTD &= ~(1 << fanPin);  // Triac gate off (LOW)

  Serial.begin(115200);
  LOGS("FIRMWARE=");
  LOGS(FIRMWARE_VERSION);
  LOGLN("");

  // Read and sanitize EEPROM-backed states
  byte powerState = EEPROM.read(power_addr);
  if (powerState != STATE_OFF && powerState != STATE_ON) powerState = STATE_OFF;
  eeprom_power_state = powerState;

  eeprom_fan_state = EEPROM.read(fan_addr);
  if (eeprom_fan_state != STATE_OFF && eeprom_fan_state != STATE_ON) eeprom_fan_state = STATE_OFF;

  eeprom_fan_level = EEPROM.read(fan_lvl);
  if (eeprom_fan_level < 1 || eeprom_fan_level > 9) eeprom_fan_level = 1;

  eeprom_min_percent = EEPROM.read(fan_min_pct_addr);
  if (eeprom_min_percent > 100 || eeprom_min_percent == 0xFF) {
    eeprom_min_percent = 5;
    EEPROM.update(fan_min_pct_addr, eeprom_min_percent);
  }
  LOGS("MINP=");
  LOG((int)eeprom_min_percent);
  LOGLN("");

  eeprom_light1_state = EEPROM.read(light1_addr);
  if (eeprom_light1_state != STATE_OFF && eeprom_light1_state != STATE_ON) eeprom_light1_state = STATE_OFF;
  eeprom_light2_state = EEPROM.read(light2_addr);
  if (eeprom_light2_state != STATE_OFF && eeprom_light2_state != STATE_ON) eeprom_light2_state = STATE_OFF;
  eeprom_socket_state = EEPROM.read(socket_addr);
  if (eeprom_socket_state != STATE_OFF && eeprom_socket_state != STATE_ON) eeprom_socket_state = STATE_OFF;

  // Configure INT0 for falling-edge zero-cross detection
  MCUCR &= ~(1 << ISC00);
  MCUCR |= (1 << ISC01);
  GICR |= (1 << INT0);

  // Initialize hardware to persisted states
  if (eeprom_power_state == STATE_OFF) {
    PORTC &= ~((1 << socketPin) | (1 << light1Pin) | (1 << light2Pin));
    display(10);
    fireEnabled = false;
    atomicWriteUI(targetDelayTicks, MAX_DELAY_TICKS + 1);
  } else {
    // Apply outputs
    byte portCState = PORTC;
    if (eeprom_light1_state == STATE_ON) portCState |= (1 << light1Pin);
    else portCState &= ~(1 << light1Pin);
    if (eeprom_light2_state == STATE_ON) portCState |= (1 << light2Pin);
    else portCState &= ~(1 << light2Pin);
    if (eeprom_socket_state == STATE_ON) portCState |= (1 << socketPin);
    else portCState &= ~(1 << socketPin);
    PORTC = portCState;

    if (eeprom_fan_state == STATE_OFF) {
      display(11);
    } else {
      // Use pending mechanism to start fan after a short boot delay
      // This allows the Zero-Cross sync to stabilize before firing.
      pendingFanLevel = eeprom_fan_level;
      pendingDisplayDigit = eeprom_fan_level;
      atomicWriteUL(pendingApplyTime, millis() + 500);  // 500ms startup delay
      display(pendingDisplayDigit);
    }
  }

  sei();  // Enable interrupts at the very end of setup
}

void loop() {
  // Reset IR-driven software button states each loop
  PowerSwState = HIGH;
  FanSwState = HIGH;
  PlusSwState = HIGH;
  MinusSwState = HIGH;
  Light1SwState = HIGH;
  Light2SwState = HIGH;
  SocketSwState = HIGH;
  IR_Detect();

  // apply pending scheduled fan change when timed
  unsigned long pendingTime = atomicReadUL(pendingApplyTime);
  if (pendingTime != 0 && (millis() >= pendingTime)) {
    atomicWriteUL(pendingApplyTime, 0);
    // commit pending fan change
    setFanLevel(pendingFanLevel, pendingDisplayDigit);
    // consumed
    pendingFanLevel = 0;
  }

  static char cmdBuf[48];
  static byte cmdPos = 0;

  // Line-buffered serial command parser (structured protocol FV5.1.0)
  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (cmdPos > 0) {
        cmdBuf[cmdPos] = '\0';
        processSerialCommand(cmdBuf);
        cmdPos = 0;
      }
    } else {
      // Normalize to uppercase
      if (c >= 'a' && c <= 'z') c -= 32;
      if (cmdPos < sizeof(cmdBuf) - 1) {
        cmdBuf[cmdPos++] = c;
      } else {
        // Buffer overflow → discard
        cmdPos = 0;
        LOGLNS("ERR:OVERFLOW");
      }
    }
  }

  // IR-driven software switch handlers (unchanged)
  if ((PowerSwState != LastPowerSwState) || (FanSwState != LastFanSwState) || (PlusSwState != LastPlusSwState) || (MinusSwState != LastMinusSwState) || (SocketSwState != LastSocketSwState) || (Light1SwState != LastLight1SwState) || (Light2SwState != LastLight2SwState)) {
    if (PowerSwState == LOW) handlePowerSwitch();
    else if (FanSwState == LOW) handleFanSwitch();
    else if (PlusSwState == LOW) handleFanPlus();
    else if (MinusSwState == LOW) handleFanMinus();
    else if (Light1SwState == LOW) handleLight1Switch();
    else if (Light2SwState == LOW) handleLight2Switch();
    else if (SocketSwState == LOW) handleSocketSwitch();

    // Broadcast status after local/IR state change so ESP updates its cache
    sendStructuredStatus();
  }

  LastPowerSwState = PowerSwState;
  LastFanSwState = FanSwState;
  LastPlusSwState = PlusSwState;
  LastMinusSwState = MinusSwState;
  LastSocketSwState = SocketSwState;
  LastLight1SwState = Light1SwState;
  LastLight2SwState = Light2SwState;

  // Watchdog-like frequency check for zero-cross & fire
  static unsigned long lastCheck = 0;
  if (millis() - lastCheck > WATCHDOG_CHECK_INTERVAL_MS) {
    lastCheck = millis();
    unsigned long lastFireCopy = atomicReadUL(lastFire);
    if (fireEnabled && (micros() - lastFireCopy > (WATCHDOG_TIMEOUT_MS * 1000UL))) {
      LOGLNS("ERR: ZC LOST!");
      fireEnabled = false;
      wasDisabledByWatchdog = true;
      watchdogDisableTime = millis();
      recoveryAttempts = 0;
      resetTriacCounters();
    } else if (wasDisabledByWatchdog && !fireEnabled) {
      unsigned long lastZCCopy = atomicReadUL(lastZC);
      unsigned long zcAge = micros() - lastZCCopy;
      if (zcAge < SPONTANEOUS_RECOVERY_WINDOW_US && eeprom_power_state == STATE_ON && eeprom_fan_state == STATE_ON) {
        LOGLNS("ZC OK: resume fan");
        wasDisabledByWatchdog = false;
        recoveryAttempts = 0;
        setFanDisplay(lastValidLevel);
      }
    }
  }

  // Auto-recovery attempts
  if (AUTO_RECOVERY_ENABLED && wasDisabledByWatchdog && eeprom_power_state == STATE_ON && eeprom_fan_state == STATE_ON) {
    if ((millis() - watchdogDisableTime) > (AUTO_RECOVERY_DELAY_SEC * 1000UL)) {
      if (recoveryAttempts < MAX_RECOVERY_ATTEMPTS) {
        LOGS("RECOVERY:");
        LOG(recoveryAttempts + 1);
        LOGLN("/3");
        setFanDisplay(lastValidLevel);
        recoveryAttempts++;
        watchdogDisableTime = millis();
      } else if (recoveryAttempts == MAX_RECOVERY_ATTEMPTS) {
        LOGLNS("REC MAX");
        recoveryAttempts++;
      }
    }
  }
}

// Section: IR detection and parsing.
// Warning: IR decoding is blocking and may delay main loop responsiveness.
// For production, consider moving IR decode to interrupts or timer logic.
void IR_Detect() {
  if (PINB & (1 << irPin)) return;  // No IR signal, exit immediately to prevent blocking
  int Code = getSIRC12();
  if (Code != -1) {
    unsigned long msNow = millis();
    unsigned long debounceTime = (Code == 0xF03 || Code == 0xF04) ? 200UL : 600UL;
    // ignore immediate repeats of the same code
    if ((Code == lastIRCode) && ((msNow - lastIRMillis) < debounceTime)) {
      return;
    }
    lastIRCode = Code;
    lastIRMillis = msNow;
    LOGS("IR:");
    LOG(Code, HEX);
    LOGLN("");
    if (Code == 0xF01) PowerSwState = LOW;
    else if (Code == 0xF02) FanSwState = LOW;
    else if (Code == 0xF03) PlusSwState = LOW;
    else if (Code == 0xF04) MinusSwState = LOW;
    else if (Code == 0xF05) Light1SwState = LOW;
    else if (Code == 0xF06) Light2SwState = LOW;
    else if (Code == 0xF07) SocketSwState = LOW;
  }
}

int getSIRC12() {
  if (pulseInPB2LOW(IR_LEADER_TIMEOUT_US) > IR_LEADER_US) {
    int IRCode = 0;
    for (int i = 0; i < 12; ++i) IRCode |= (pulseInPB2LOW(IR_BIT_TIMEOUT_US) > IR_BIT_US) << i;
    for (int j = 0; j < 7; ++j)
      if (IRCode == pgm_read_word_near(validCodes + j)) return IRCode;
  }
  return -1;
}

// Custom pulseIn for PB2 LOW-only SIRC decoding.
unsigned long pulseInPB2LOW(unsigned long timeout) {
  uint8_t irMask = (1 << irPin);
  unsigned long startWait = micros();
  // Wait for start of LOW pulse (HIGH to LOW transition), with overall timeout
  while ((micros() - startWait) < timeout) {
    if (!(PINB & irMask)) break;  // Exit when LOW starts
  }
  if ((micros() - startWait) >= timeout) return 0;  // Timed out waiting for LOW start

  // Now time the LOW duration
  unsigned long pulseStart = micros();
  unsigned long elapsed;
  while ((elapsed = micros() - pulseStart) < timeout) {
    if (PINB & irMask) return elapsed;  // HIGH detected: end of LOW
  }
  return elapsed;  // Timeout during LOW: return partial duration
}

// Section: Interrupt service routines.
ISR(INT0_vect) {
  unsigned long now = micros();
  if ((now - lastZeroCross) < ZC_DEBOUNCE_US) return;
  lastZeroCross = now;
  lastZC = now;
  zcCount++;
  zcParity = !zcParity;

  // Handle Level 9 (100% conduct) - Hard bypass for pure AC performance
  if (fireEnabled && eeprom_fan_level == 9) {
    PORTD |= (1 << fanPin);  // Immediate fire at zero-cross
    timerActive = false;
    return;
  }

  if (!fireEnabled || timerActive) return;

  unsigned int ticks = targetDelayTicks;
  if (ticks < MIN_DELAY_TICKS) ticks = MIN_DELAY_TICKS;
  if (ticks > MAX_DELAY_TICKS) return;

  TCNT1 = 0;
  OCR1A = ticks;
  TCCR1A = 0;
  TCCR1B = (1 << WGM12) | (1 << CS11) | (1 << CS10);  // CTC, prescaler 64
  TIMSK |= (1 << OCIE1A);
  timerActive = true;
  triacPulseActive = false;
  scheduledParity = zcParity;
}

ISR(TIMER1_COMPA_vect) {
  if (!triacPulseActive) {
    if (fireEnabled) {
      PORTD |= (1 << fanPin);
      triacPulseActive = true;
      unsigned int gateTicks = (GATE_PULSE_US + TIMER_TICK_US - 1) / TIMER_TICK_US;
      OCR1A = gateTicks;
      triacFiresTotal++;
      if (scheduledParity) triacFiresParity[1]++;
      else triacFiresParity[0]++;
    } else {
      TCCR1B = 0;
      timerActive = false;
      triacPulseActive = false;
    }
  } else {
    // Only clear the pin if we are NOT in hard Level 9 conduct mode
    if (eeprom_fan_level != 9) {
      PORTD &= ~(1 << fanPin);
    }
    lastFire = micros();
    triacPulseActive = false;
    TCCR1B = 0;
    timerActive = false;
  }
}

// Section: Utility helpers.
void display(byte digitIndex) {
  if (digitIndex > 11) digitIndex = 10;
  byte segments = pgm_read_byte_near(digitSegments + digitIndex);
  uint8_t portD_set = 0, portD_clear = 0;
  uint8_t portB_set = 0, portB_clear = 0;
  uint8_t portC_set = 0, portC_clear = 0;
  for (int i = 0; i < 7; ++i) {
    byte mask = pgm_read_byte_near(segmentBitMasks + i);
    if (segments & (1 << i)) {
      switch (i) {
        case 0: portD_clear |= mask; break;
        case 1: portB_clear |= mask; break;
        case 2: portC_clear |= mask; break;
        case 3: portC_clear |= mask; break;
        case 4: portC_clear |= mask; break;
        case 5: portD_clear |= mask; break;
        case 6: portD_clear |= mask; break;
      }
    } else {
      switch (i) {
        case 0: portD_set |= mask; break;
        case 1: portB_set |= mask; break;
        case 2: portC_set |= mask; break;
        case 3: portC_set |= mask; break;
        case 4: portC_set |= mask; break;
        case 5: portD_set |= mask; break;
        case 6: portD_set |= mask; break;
      }
    }
  }
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    PORTD = (PORTD & ~(portD_clear | portD_set)) | portD_set;
    PORTB = (PORTB & ~(portB_clear | portB_set)) | portB_set;
    PORTC = (PORTC & ~(portC_clear | portC_set)) | portC_set;
  }
}

// Update target delay for the requested fan level and refresh display.
// Wrapper for setFanLevel using the same display digit.
void setFanDisplay(byte fanLevelEEPROM) {
  setFanLevel(fanLevelEEPROM, fanLevelEEPROM);
}

// Section: Event handlers.
void handlePowerSwitch() {
  if (eeprom_power_state == STATE_OFF) {
    byte portCState = PORTC;
    if (eeprom_light1_state == STATE_ON) portCState |= (1 << light1Pin);
    else portCState &= ~(1 << light1Pin);
    if (eeprom_light2_state == STATE_ON) portCState |= (1 << light2Pin);
    else portCState &= ~(1 << light2Pin);
    if (eeprom_socket_state == STATE_ON) portCState |= (1 << socketPin);
    else portCState &= ~(1 << socketPin);

    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
      PORTC = portCState;
      if (eeprom_fan_state == STATE_ON) {
        // Fan will start via the loop's pending mechanism or setFanDisplay
      }
    }

    if (eeprom_fan_state == STATE_OFF) display(11);
    else setFanDisplay(eeprom_fan_level);

    EEPROM.update(power_addr, STATE_ON);
    eeprom_power_state = STATE_ON;
    resetTriacCounters();
  } else {
    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
      PORTC &= ~((1 << socketPin) | (1 << light1Pin) | (1 << light2Pin));
      PORTD &= ~(1 << fanPin);
      fireEnabled = false;
      TCCR1B = 0;
      timerActive = false;
    }
    display(10);
    EEPROM.update(power_addr, STATE_OFF);
    eeprom_power_state = STATE_OFF;
    resetTriacCounters();
  }
}

void handleFanSwitch() {
  if ((eeprom_fan_state == STATE_OFF) && (eeprom_power_state == STATE_ON)) {
    pendingFanLevel = eeprom_fan_level;
    pendingDisplayDigit = eeprom_fan_level;
    atomicWriteUL(pendingApplyTime, millis() + 120);
    display(pendingDisplayDigit);
    EEPROM.update(fan_addr, STATE_ON);
    eeprom_fan_state = STATE_ON;
  } else if ((eeprom_fan_state == STATE_ON) && (eeprom_power_state == STATE_ON)) {
    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
      fireEnabled = false;
      PORTD &= ~(1 << fanPin);
      TCCR1B = 0;
      timerActive = false;
    }
    display(11);
    EEPROM.update(fan_addr, STATE_OFF);
    eeprom_fan_state = STATE_OFF;
    resetTriacCounters();
  }
}

void handleFanPlus() {
  if ((eeprom_fan_state == STATE_ON) && (eeprom_power_state == STATE_ON)) {
    byte currentLevel = eeprom_fan_level;
    byte index = currentLevel - 1;
    if (index < 8) {
      byte newIndex = index + 1;
      // schedule the change to reduce transient spikes if user presses fast
      pendingFanLevel = newIndex + 1;
      pendingDisplayDigit = newIndex + 1;
      atomicWriteUL(pendingApplyTime, millis() + IR_COMMAND_DEBOUNCE_MS);
      display(pendingDisplayDigit);
    }
  }
}

void handleFanMinus() {
  if ((eeprom_fan_state == STATE_ON) && (eeprom_power_state == STATE_ON)) {
    byte currentLevel = eeprom_fan_level;
    byte index = currentLevel - 1;
    if (index > 0) {
      byte newIndex = index - 1;
      // schedule the change to reduce transient spikes if user presses fast
      pendingFanLevel = newIndex + 1;
      pendingDisplayDigit = newIndex + 1;
      atomicWriteUL(pendingApplyTime, millis() + IR_COMMAND_DEBOUNCE_MS);
      display(pendingDisplayDigit);
    }
  }
}

void setFanLevel(byte levelEEPROM, byte displayDigit) {
  byte level = (levelEEPROM < 1) ? 1 : (levelEEPROM);
  if (level > 9) level = 9;
  byte Pmin = eeprom_min_percent;
  unsigned int Ptarget = (unsigned int)Pmin + ((unsigned int)(level - 1) * (100 - Pmin) + 4) / 8;
  if (Ptarget > 100) Ptarget = 100;
  unsigned int delay_us = pgm_read_word_near(DELAY_FROM_PERCENT + Ptarget);
  unsigned int ticks = (delay_us + TIMER_TICK_US - 1) / TIMER_TICK_US;
  if (ticks < MIN_DELAY_TICKS) ticks = MIN_DELAY_TICKS;
  if (ticks > MAX_DELAY_TICKS) ticks = MAX_DELAY_TICKS;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    // commit new target ticks and update volatile variables atomically
    targetDelayTicks = ticks;  // Direct assignment inside ATOMIC_BLOCK
    eeprom_fan_level = level;
    lastValidLevel = level;
    fireEnabled = true;
  }
  // persist the sanitized level without blocking interrupts
  EEPROM.update(fan_lvl, level);
  // display selection: if there is a requested displayDigit, prefer that (sanitized)
  if (displayDigit <= 11) display(displayDigit);
  else display(level);
}

void handleLight1Switch() {
  if (eeprom_power_state == STATE_ON) toggleOutput(light1_addr, light1Pin, PORTC, eeprom_light1_state);
}
void handleLight2Switch() {
  if (eeprom_power_state == STATE_ON) toggleOutput(light2_addr, light2Pin, PORTC, eeprom_light2_state);
}
void handleSocketSwitch() {
  if (eeprom_power_state == STATE_ON) toggleOutput(socket_addr, socketPin, PORTC, eeprom_socket_state);
}

void toggleOutput(byte addr, byte pin, volatile uint8_t &port, volatile uint8_t &cachedState) {
  uint8_t newState;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    if (cachedState == STATE_OFF) {
      port |= (1 << pin);
      cachedState = STATE_ON;
      newState = STATE_ON;
    } else {
      port &= ~(1 << pin);
      cachedState = STATE_OFF;
      newState = STATE_OFF;
    }
  }
  // Persist the change outside the ATOMIC_BLOCK to avoid long interrupt disable
  EEPROM.update(addr, newState);
}

// Section: Structured command protocol (FV5.1.0).
// Replaces single-character toggle commands with explicit state commands.
// Format: SET:<DEVICE>:<STATE> or GET:<QUERY>.
// Response: OK:<DEVICE>:<STATE> or ERR:<REASON>.

void processSerialCommand(const char *cmd) {
  // SET commands.
  if (strncmp(cmd, "SET:", 4) == 0) {
    const char *sub = cmd + 4;

    // SET:PWR:ON / SET:PWR:OFF
    if (strncmp(sub, "PWR:", 4) == 0) {
      bool on = (strncmp(sub + 4, "ON", 2) == 0);
      setPower(on);
      LOGS("OK:PWR:");
      LOGLN(on ? "ON" : "OFF");
    }
    // SET:FAN:ON / SET:FAN:OFF / SET:FAN:SPD:N
    else if (strncmp(sub, "FAN:", 4) == 0) {
      if (strncmp(sub + 4, "SPD:", 4) == 0) {
        int level = atoi(sub + 8);
        if (eeprom_power_state == STATE_OFF) {
          LOGLNS("ERR:PWR_OFF");
        } else if (level < 1 || level > 9) {
          LOGLNS("ERR:RANGE");
        } else {
          setFanSpeed(level);
          LOGS("OK:FAN:SPD:");
          LOG(level);
          LOGLN("");
        }
      } else if (strncmp(sub + 4, "ON", 2) == 0) {
        if (eeprom_power_state == STATE_OFF) {
          LOGLNS("ERR:PWR_OFF");
        } else {
          setFan(true);
          LOGS("OK:FAN:ON:");
          LOG((int)eeprom_fan_level);
          LOGLN("");
        }
      } else if (strncmp(sub + 4, "OFF", 3) == 0) {
        if (eeprom_power_state == STATE_OFF) {
          LOGLNS("ERR:PWR_OFF");
        } else {
          setFan(false);
          LOGLNS("OK:FAN:OFF");
        }
      } else {
        LOGLNS("ERR:INVALID");
      }
    }
    // SET:LT1:ON / SET:LT1:OFF
    else if (strncmp(sub, "LT1:", 4) == 0) {
      if (eeprom_power_state == STATE_OFF) {
        LOGLNS("ERR:PWR_OFF");
      } else {
        bool on = (strncmp(sub + 4, "ON", 2) == 0);
        setOutputExplicit(light1_addr, light1Pin, PORTC, eeprom_light1_state, on);
        LOGS("OK:LT1:");
        LOGLN(on ? "ON" : "OFF");
      }
    }
    // SET:LT2:ON / SET:LT2:OFF
    else if (strncmp(sub, "LT2:", 4) == 0) {
      if (eeprom_power_state == STATE_OFF) {
        LOGLNS("ERR:PWR_OFF");
      } else {
        bool on = (strncmp(sub + 4, "ON", 2) == 0);
        setOutputExplicit(light2_addr, light2Pin, PORTC, eeprom_light2_state, on);
        LOGS("OK:LT2:");
        LOGLN(on ? "ON" : "OFF");
      }
    }
    // SET:PLG:ON / SET:PLG:OFF
    else if (strncmp(sub, "PLG:", 4) == 0) {
      if (eeprom_power_state == STATE_OFF) {
        LOGLNS("ERR:PWR_OFF");
      } else {
        bool on = (strncmp(sub + 4, "ON", 2) == 0);
        setOutputExplicit(socket_addr, socketPin, PORTC, eeprom_socket_state, on);
        LOGS("OK:PLG:");
        LOGLN(on ? "ON" : "OFF");
      }
    }
    // SET:MINP:NN
    else if (strncmp(sub, "MINP:", 5) == 0) {
      int v = atoi(sub + 5);
      if (v < 0) v = 0;
      if (v > 100) v = 100;
      EEPROM.update(fan_min_pct_addr, (uint8_t)v);
      eeprom_min_percent = (uint8_t)v;
      if (eeprom_fan_state == STATE_ON && eeprom_power_state == STATE_ON) {
        setFanDisplay(eeprom_fan_level);
      }
      LOGS("OK:MINP:");
      LOG(v);
      LOGLN("");
    } else {
      LOGLNS("ERR:INVALID");
    }
  }
  // GET commands.
  else if (strncmp(cmd, "GET:", 4) == 0) {
    const char *sub = cmd + 4;
    if (strncmp(sub, "STATUS", 6) == 0) {
      sendStructuredStatus();
    } else if (strncmp(sub, "MINP", 4) == 0) {
      LOGS("OK:MINP:");
      LOG((int)eeprom_min_percent);
      LOGLN("");
    } else {
      LOGLNS("ERR:INVALID");
    }
  }
  // Unknown command.
  else {
    LOGLNS("ERR:INVALID");
  }
}

// Set power to explicit state (idempotent).
void setPower(bool on) {
  if (on && eeprom_power_state == STATE_OFF) handlePowerSwitch();
  else if (!on && eeprom_power_state == STATE_ON) handlePowerSwitch();
}

// Set fan to explicit on or off state (requires power ON).
void setFan(bool on) {
  if (eeprom_power_state == STATE_OFF) return;
  if (on && eeprom_fan_state == STATE_OFF) handleFanSwitch();
  else if (!on && eeprom_fan_state == STATE_ON) handleFanSwitch();
}

// Set fan to a specific speed level (1-9); auto-enable if off.
void setFanSpeed(int level) {
  if (level < 1) level = 1;
  if (level > 9) level = 9;
  if (eeprom_power_state == STATE_OFF) return;
  // If fan is off, turn it on first
  if (eeprom_fan_state == STATE_OFF) {
    handleFanSwitch();
  }
  // Schedule the speed change via the pending mechanism
  pendingFanLevel = (byte)level;
  pendingDisplayDigit = (byte)level;
  atomicWriteUL(pendingApplyTime, millis() + IR_COMMAND_DEBOUNCE_MS);
  display((byte)level);
}

// Set output to explicit state (idempotent).
void setOutputExplicit(byte addr, byte pin, volatile uint8_t &port, volatile uint8_t &cachedState, bool on) {
  if (eeprom_power_state == STATE_OFF) return;
  bool currentlyOn = (cachedState == STATE_ON);
  if (on == currentlyOn) return;  // Already in desired state; no operation.
  toggleOutput(addr, pin, port, cachedState);
}

// Send compact machine-parseable status response.
void sendStructuredStatus() {
  const char *pwr = (eeprom_power_state == STATE_ON) ? "ON" : "OFF";
  const char *fan = (eeprom_fan_state == STATE_ON) ? "ON" : "OFF";
  const char *lt1 = (eeprom_light1_state == STATE_ON) ? "ON" : "OFF";
  const char *lt2 = (eeprom_light2_state == STATE_ON) ? "ON" : "OFF";
  const char *plg = (eeprom_socket_state == STATE_ON) ? "ON" : "OFF";
  LOGS("STATUS:PWR=");
  LOG(pwr);
  LOGS(",FAN=");
  LOG(fan);
  LOGS(",SPD=");
  LOG((int)eeprom_fan_level);
  LOGS(",LT1=");
  LOG(lt1);
  LOGS(",LT2=");
  LOG(lt2);
  LOGS(",PLG=");
  LOG(plg);
  LOGS(",MINP=");
  LOG((int)eeprom_min_percent);
  LOGS(",FW=");
  LOGS(FIRMWARE_VERSION);
  LOGLN("");
}
