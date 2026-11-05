/// Tesla CAN signals, from the public Model 3 DBC (github.com/joshwardell/
/// model3dbc, MIT) unless an entry names another source, most often
/// talas9's 2026.26 Model Y DBCs (github.com/talas9/tesla-can-signal-db).
/// Bit numbering is DBC `@1`, i.e. little-endian/Intel, which is what
/// `decode` implements.
///
/// Anything you want to add: find the `SG_` line in that DBC and copy the
/// `start|len@1±  (scale,offset)` numbers across. Nothing else has to change —
/// the id is subscribed automatically.
class Sig {
  const Sig(
    this.id,
    this.start,
    this.len, {
    this.scale = 1,
    this.offset = 0,
    this.signed = false,
    this.sna,
    this.mux,
    this.muxStart = 0,
    this.muxLen = 3,
  });

  final int id; // CAN arbitration id
  final int start; // start bit
  final int len; // bit length
  final double scale;
  final double offset;
  final bool signed;

  /// Raw value the car sends for "signal not available". Decoding it would
  /// otherwise produce a confident wrong number (SNA speed reads 287 km/h).
  final int? sna;

  /// Some messages (VCFRONT_status) rotate through several payloads. When
  /// [mux] is set the frame only carries this signal if the selector field
  /// at [muxStart]|[muxLen] holds that value.
  final int? mux;
  final int muxStart;
  final int muxLen;
}

const kSignals = <String, Sig>{
  // ID257 DIspeed. DI_uiSpeed is the exact number on the car's screen, in
  // the car's display units (DI_vehicleSpeed is finer but rounds 1 lower).
  'speed': Sig(0x257, 24, 9, sna: 511),
  'speedIsKph': Sig(0x257, 33, 1), // DI_uiSpeedUnits: 1 kph, 0 mph

  // ID118 DriveSystemStatus
  'gear': Sig(0x118, 21, 3), // 1 P, 2 R, 3 N, 4 D
  'pedal': Sig(0x118, 32, 8, scale: 0.4, sna: 255), // %
  // ID118 DI_vehicleAcceleration: the drive unit's own acceleration along
  // the car, positive speeding up; raw 2048 SNA (it read that parked).
  'accel': Sig(0x118, 52, 12, scale: 0.01, signed: true, sna: 2048), // m/s²
  // ID101 RCM_inertial1, the airbag module's yaw rate (ISO: positive
  // turning left), on the Commander's stream at 49 Hz; with the speed it
  // gives the sideways g, as its own g-sensor (0x111) never comes.
  'yaw': Sig(0x101, 0, 16, scale: 0.0001, signed: true, sna: 32768), // rad/s
  // The brake pedal, 1 ON. DI_brakePedalState (19|2: 0 OFF, 1 ON, 2 INVALID)
  // reads INVALID at all times since 2026.38. Bit 51 took over, found from
  // the car's trace: set with the accelerator at 0 while stopping or held at
  // a stop, clear while driving on it and coasting with regen, and clear in
  // P with the foot off; bits 48-50 beside it stay 0.
  'brake': Sig(0x118, 51, 1),

  // ID2E5 FrontInverterPower / ID266 RearInverterPower. Firmware 2026.38
  // repacked both into 7 bytes: the power moved from 0|11 to 41|11, after
  // the drive power limit (now 32|9: rear 392 kW, front 208). Found from the
  // car's trace: +4 kW pulling away, -4 kW slowing, 0 parked. The old spot
  // now reads e.g. -382.5 kW parked. Raw 1024 is SNA, else full regen.
  'frontKw': Sig(0x2E5, 41, 11, scale: 0.5, signed: true, sna: 1024),
  'rearKw': Sig(0x266, 41, 11, scale: 0.5, signed: true, sna: 1024),
  // ID132 BMS_hvBusStatus, ~68 a second: the pack's voltage and current, to
  // move the motor readouts between those once-a-second frames (see
  // Panda._blend). Current comes in after voltage: same frame, this order.
  // Discharge is negative here: battery kW = -V x A (the drive's trace).
  'packV': Sig(0x132, 0, 16, scale: 0.01),
  'packA': Sig(0x132, 16, 16, scale: 0.1, signed: true, sna: 32768),

  // What else draws on the pack, beside the motors (see Panda.otherKw). On
  // the drive's trace compressor + 12 V made up the whole gap to within
  // ~0.2 kW, the heat pump doing the heating (cabin heater 0).
  // ID2A7 CMPD_state: the heat pump compressor's HV input power.
  'compW': Sig(0x2A7, 21, 11, scale: 10), // W
  // ID2B4 PCS_dcdcRailStatus: the 12 V side, volts then amps (same frame,
  // this order): everything low-voltage, seat heaters and screens included.
  'lvV': Sig(0x2B4, 0, 13, scale: 0.01),
  'lvA': Sig(0x2B4, 32, 13, scale: 0.1, signed: true),
  // ID2B3 page 2: the cabin's resistive heater per zone.
  'heatL': Sig(0x2B3, 16, 10, scale: 5, mux: 2, muxLen: 5), // W
  'heatR': Sig(0x2B3, 26, 10, scale: 5, mux: 2, muxLen: 5), // W

  // ID33A UI_rangeSOC. Current firmware packs this tighter than the public
  // DBC: Range 0|10, Wh/mi 10|10, SOC 20|7, uSOE 27|7. Derived from a
  // live capture (CD AC B3 DB FD FF E5 68 -> 205 mi, 235 Wh/mi, 59 %, 59 %),
  // where the DBC offsets decoded to nonsense. SOCUI292 on 0x292 is the
  // BMS figure and runs ~2 % above what the screen shows.
  'soc': Sig(0x33A, 20, 7), // %
  'rangeMi': Sig(0x33A, 0, 10),

  // ID332 BMS_bmbMinMax, payload 1: highest and lowest brick (parallel cell
  // group) voltage. Same layout in the public DBC and the newer Onyx M2 one.
  'cellVMax': Sig(0x332, 2, 12, scale: 0.002, mux: 1, muxLen: 2), // V
  'cellVMin': Sig(0x332, 16, 12, scale: 0.002, mux: 1, muxLen: 2), // V

  // ID352 BMS_energyStatus, payload 0: nominal full-pack energy. Current
  // firmware multiplexes this message (github.com/onyx-m2/onyx-m2-dbc); the
  // public DBC's 0|11 layout is the pre-2021 one. Seen in a capture from the
  // car: full 81.76, left 50.62, buffer 3.68 kWh while the screen
  // said 60 %, which is (left - buffer) / (full - buffer).
  'packKwh': Sig(0x352, 16, 16, scale: 0.02, mux: 0, muxLen: 2),
  'packLeftKwh': Sig(0x352, 32, 16, scale: 0.02, mux: 0, muxLen: 2),
  // Payload 1: the energy kept below the screen's 0 %, 0.01 kWh a count.
  'packBufferKwh': Sig(0x352, 16, 16, scale: 0.01, mux: 1, muxLen: 2),

  // ID392 BMS_packConfig, payload 1: pack energy when new, per the 2026.26
  // Model Y DBC (github.com/talas9/tesla-can-signal-db); the public DBC had it
  // at 0x292 40|10. The party bus reuses 0x392 for EPAS alerts, so Panda
  // takes it only from the BMS's bus, and only when plausible.
  'packNewKwh': Sig(0x392, 40, 10, scale: 0.1, sna: 1023, mux: 1, muxLen: 8),

  // ID273 UI_vehicleControl: the screen's dome light switch, which lights the
  // dash's LIGHT button. Same bits in the public and 2026.26 DBCs; not yet
  // seen on this car.
  'domeLight': Sig(0x273, 59, 2), // see kDome
  // UI_mirrorDipOnReverse, the screen's Mirror Auto Tilt (validated).
  'tiltAuto': Sig(0x273, 53, 1),
  // ID3E2 VCLEFT_lightStatus, vehicle bus, 7 bytes, 5 Hz: the four overhead
  // map lights at 6/8/10/12, each 0 OFF, 1 ON, 2 FAULT, 3 SNA; what the S3XY
  // Interior Lights press turns on. The chassis bus has an unrelated 8-byte
  // 0x3E2 (Juniper capture), so Panda takes only 7-byte frames.
  'mapLights': Sig(0x3E2, 6, 8),

  // Door latches. ID102 VCLEFT_doorStatus / ID103 VCRIGHT_doorStatus.
  // 1 OPENED, 2 CLOSED, 5 AJAR — see kLatchOpen. Verified against a parked
  // capture where all five read CLOSED.
  'doorFL': Sig(0x102, 0, 4, sna: 0),
  'doorRL': Sig(0x102, 4, 4, sna: 0),
  'doorFR': Sig(0x103, 0, 4, sna: 0),
  'doorRR': Sig(0x103, 4, 4, sna: 0),
  'trunk': Sig(0x103, 56, 4, sna: 0),
  // VCLEFT_mirrorDipped, 2026.26 DBC (rated plausible): the mirrors are
  // tilted down, which is what the TILT button toggles in R.
  'mirrorDipped': Sig(0x102, 63, 1),

  // ID2E1 VCFRONT_status, payload 0 only.
  'frunk': Sig(0x2E1, 3, 4, sna: 0, mux: 0),

  // ID25D CP_status: CP_chargeDoorOpen, 1 = the charge port door is open
  // (2026.26 DBC, rated plausible; 100 ms). The chassis bus may carry a
  // 6-byte frame on the same id, so Panda takes only 8-byte ones.
  'chargePort': Sig(0x25D, 6, 1),

  // ID3A1 VCFRONT_vehicleStatus, mux 0|1. Chime per seat: 0 none, 1 occupied
  // and unbuckled, 2 SNA. Rows 1 and 2 are in payload 0, the third row in
  // payload 1 (2026.26 and dzid26 DBCs). Payload 1 carries PCS current over
  // the row 1-2 bits, which made the warning flicker before the mux was
  // checked. No sna: an SNA frame must clear a seat, not freeze it.
  'beltDriver': Sig(0x3A1, 32, 2, mux: 0, muxLen: 1),
  'beltPass': Sig(0x3A1, 34, 2, mux: 0, muxLen: 1),
  'belt2L': Sig(0x3A1, 36, 2, mux: 0, muxLen: 1),
  'belt2C': Sig(0x3A1, 38, 2, mux: 0, muxLen: 1),
  'belt2R': Sig(0x3A1, 40, 2, mux: 0, muxLen: 1),
  'belt3L': Sig(0x3A1, 2, 2, mux: 1, muxLen: 1),
  'belt3R': Sig(0x3A1, 4, 2, mux: 1, muxLen: 1),
  // The buckles themselves, per the 2026.26 DBC. The left body controller's
  // switches (ID3C2 VCLEFT_switchStatus, page 0: 1 OFF, 2 ON; rated
  // validated) for the driver and the second row's left and centre; the
  // right one's buckle states (ID31A VCRIGHT_restraintStatus: 0 UNLATCHED,
  // 1 LATCHED, 3 NOT_CONFIGURED, which its second-row centre reads on the
  // test car; rated plausible) for the passenger, the second row's right
  // and the third row, whose left switch on 0x3C2 page 1 reads SNA there.
  // In logs from the car the driver's switch read OFF while the belt chimed
  // and ON once buckled; the other seats are yet to be seen buckled.
  'buckleD': Sig(0x3C2, 48, 2, mux: 0, muxLen: 1),
  'buckle2L': Sig(0x3C2, 52, 2, mux: 0, muxLen: 1),
  'buckle2C': Sig(0x3C2, 62, 2, mux: 0, muxLen: 1),
  'buckleP': Sig(0x31A, 3, 2),
  'buckle2R': Sig(0x31A, 8, 2),
  'buckle3L': Sig(0x31A, 12, 2),
  'buckle3R': Sig(0x31A, 14, 2),

  // ID3F5 VCFRONT_lighting, 100 ms, 2026.26 layout (the indicators below
  // confirm the frame arrives). 32|4 lightingCoreState: 0 OFF, 1 POS_PARK,
  // 2 DRL, 3 DRL + rear position, 4 LOW_BEAMS, 5 CUSTOM (light shows),
  // 15 SNA. On a Juniper capture the front light bar is lit in 1-4: as DRL
  // by day, as the position lamp with headlights or parking lights. 36 is
  // the high-beam flash, 37 latched high beams.
  'lowBeam': Sig(0x3F5, 32, 4),
  'drl': Sig(0x3F5, 32, 4),
  'highBeam': Sig(0x3F5, 36, 2),
  // ID3F6 VCFRONT_lightStatus, 1 s and on change: the high-beam lamps
  // themselves, left | right << 2, 1 = ON. Auto and adaptive high beams
  // light them without the 0x3F5 bits, as far as public data shows.
  'highLamp': Sig(0x3F6, 4, 4),

  // ID243 VCRIGHT_hvacStatus, mux 0|3, 20 ms: what the HVAC controller acts
  // on, so an S3XY press shows, unlike the screen's own request (0x2F3).
  // Page 0: intake mode (0 AUTO, 1 RECIRC, 2 FRESH) and power state (0 OFF);
  // page 1: the share of the air being recirculated, %. Seen on Model Y
  // logs, not yet on a Juniper: the Commander's own value stands in.
  'recirc': Sig(0x243, 48, 2, mux: 0),
  'hvacPower': Sig(0x243, 51, 3, mux: 0),
  'recircPct': Sig(0x243, 10, 6, scale: 1.6, mux: 1),

  // ID399 DAS_status. Raw units follow the car's display (kph or mph).
  // NOTE: this one lives on the chassis bus. If the sign stays blank, the
  // Commander is only forwarding the vehicle bus.
  'speedLimit': Sig(0x399, 8, 5, scale: 5, sna: 0), // 31 also means "none"

  // ID399 DAS_status, chassis bus.
  // See kAutopilot. No sna: 15 (SNA) maps to null and clears the pill.
  'autopilot': Sig(0x399, 0, 4),
  // 1/2 = warning level, 3 SNA. No sna here: SNA must read as no warning,
  // or the last frame's glow (side warning included) would stick.
  'blindL': Sig(0x399, 4, 2),
  'blindR': Sig(0x399, 6, 2),
  'sideWarn': Sig(0x399, 34, 2), // 1 left, 2 right, 3 both

  // ID3F5 VCFRONT_lighting: indicator request, the flasher's phase: 2 lamp
  // lit (ACTIVE_HIGH), 1 dark half (ACTIVE_LOW), 0 off.
  'indL': Sig(0x3F5, 0, 2),
  'indR': Sig(0x3F5, 2, 2),

  // ID219 VCSEC_TPMSData, payload 5: last known pressure per wheel, bar.
  // The 2026 Model Y's tyre sensors talk Bluetooth to VCSEC; the old
  // TPMS_data frame (0x31F, chassis bus) only ever read 0 on this car. From
  // the 2026.26 DBC (talas9): gauge pressure, as on the car's tyre screen.
  // 0 is no reading, 254 over range, 255 not available.
  'tpFL': Sig(0x219, 16, 8, scale: 0.025, sna: 255, mux: 5),
  'tpFR': Sig(0x219, 24, 8, scale: 0.025, sna: 255, mux: 5),
  'tpRL': Sig(0x219, 32, 8, scale: 0.025, sna: 255, mux: 5),
  'tpRR': Sig(0x219, 40, 8, scale: 0.025, sna: 255, mux: 5),
  // ID25A VCSEC_TPMSDisplay: the pressures the car's tyre screen draws, same
  // scale, 1 s, no mux. Fallback while 0x219 page 5 has no reading.
  'tdFL': Sig(0x25A, 0, 8, scale: 0.025, sna: 255),
  'tdFR': Sig(0x25A, 8, 8, scale: 0.025, sna: 255),
  'tdRL': Sig(0x25A, 16, 8, scale: 0.025, sna: 255),
  'tdRR': Sig(0x25A, 24, 8, scale: 0.025, sna: 255),

  // UI_tripPlanning: 0x347 on 2026 firmware (0x082 before, same layout;
  // 2026.26 Model Y DBC, and dashkit's capture of a Juniper). kWh at arrival;
  // raw -32768 is SNA and -32767 trip too long. With no route it carries the
  // pack's remaining energy, so only [navRoute] says a route is set. The %
  // at arrival the car shows is not on the bus.
  'navEnergyKwh': Sig(0x347, 48, 16, scale: 0.01, signed: true),
  // ID238 UI_driverAssistMapData: UI_navRouteActive, "navigation route is
  // active" (the same bit in every Tesla DBC since the public one). Name and
  // distance are not on the bus; they come over Bluetooth.
  'navRoute': Sig(0x238, 29, 1),
  // ID3FD UI_autopilotControl, page 2 (index 0|3): UI_navMinutesToArrival,
  // per the 2026.26 DBC (rated plausible). Without it the minutes needed the
  // Commander added as a key to the car, which this one is not.
  'navMinutes': Sig(0x3FD, 17, 10, mux: 2),

  // The newer stats, from docs/signals-and-actions.md, each checked against
  // a capture from the car (test/obd_test.dart decodes its frames).
  // ID321 VCFRONT_sensors: the air outside, filtered on speed as the car's
  // screen shows it; washer fluid 1 LOW, 2 NORMAL.
  'outside': Sig(0x321, 40, 8, scale: 0.5, offset: -40, sna: 0), // °C
  'washer': Sig(0x321, 32, 2), // 0 SNA reads as not low: no warning sticks
  // ID2B6 DI_chassisControlStatus: the car's slippery-road verdict, and the
  // traction (TC) and stability (ESP) lamps' flash while they step in.
  'slippery': Sig(0x2B6, 13, 1),
  'tcFlash': Sig(0x2B6, 2, 1),
  'escFlash': Sig(0x2B6, 0, 1),
  // ID118 DI_systemStatus: 1 Slip Start, 6 Off-Road Assist, 7 slippery.
  'tcMode': Sig(0x118, 40, 3),
  // ID252 BMS_powerAvailable: the most regen the pack takes now.
  'regenMax': Sig(0x252, 0, 16, scale: 0.01), // kW
  // ID332 page 0: the coldest cells.
  'packTMin': Sig(0x332, 24, 8, scale: 0.5, offset: -40, mux: 0, muxLen: 2), // °C
  // The pack heating: by the motors parked (ID3A1 page 0: 2), by the heat
  // pump (page 1, W), or for a charger on the route (ID347: 1 ACTIVE_HEAT,
  // to the target).
  'motorHeat': Sig(0x3A1, 10, 3, mux: 0, muxLen: 1),
  'pumpHeat': Sig(0x3A1, 41, 7, scale: 100, mux: 1, muxLen: 1),
  'precondState': Sig(0x347, 5, 2),
  'precondTarget': Sig(0x347, 16, 8, scale: 0.25, sna: 255), // °C
  // ID2B3 VCRIGHT_logging1Hz cycles about 17 pages, each every ~2 s: page 9
  // the cabin's CO2, pages 1 and 0 the air by row.
  'co2': Sig(0x2B3, 7, 10, scale: 5, mux: 9, muxLen: 5), // ppm; raw 1023 SNA
  'cabin1': Sig(0x2B3, 24, 8, scale: 0.5, offset: -40, sna: 255, mux: 1, muxLen: 5),
  'cabin2': Sig(0x2B3, 16, 8, scale: 0.5, offset: -40, sna: 255, mux: 0, muxLen: 5),
  'cabin3': Sig(0x2B3, 40, 8, scale: 0.5, offset: -40, sna: 255, mux: 0, muxLen: 5),
  // ID2F3 UI_hvacRequest, the screen's climate: on (0 OFF; 1 ON, 2-4
  // preconditioning or overheat protection), Auto's fan level (see
  // kAutoBlower), the front fan (0 OFF, 1-10, 11 AUTO) and the second row's
  // (see kFan2). The fans read off while the climate is, and a fan on Auto
  // shows Auto's level, so both come first. These are the screen's own
  // settings: an S3XY fan press that bypasses the screen does not show.
  'climateOn': Sig(0x2F3, 26, 3),
  'autoBlower': Sig(0x2F3, 5, 3),
  'fan1': Sig(0x2F3, 16, 4),
  'fan2': Sig(0x2F3, 29, 3),
  // ID399 DAS_status: the hands-on nag (DAS_autopilotHandsOnState; 15 SNA).
  'handsOn': Sig(0x399, 42, 4),
  // ID286 DI_locStatus: cruise 2 enabled, 3 standstill, 4 overridden; the
  // set speed, and its unit (1 km/h).
  'cruiseState': Sig(0x286, 12, 3),
  'cruiseSet': Sig(0x286, 15, 9, scale: 0.5),
  'cruiseKph': Sig(0x286, 24, 1),
  // ID3F8 UI_driverAssistControl: the follow distance, less one.
  'followGap': Sig(0x3F8, 45, 3, sna: 7),
  // ID212 BMS_status: 3 CHARGING; the power going in, and the most it takes.
  'chargeStatus': Sig(0x212, 11, 3),
  'chargeKw': Sig(0x212, 14, 16, scale: 0.05, sna: 65535),
  'chargeMaxKw': Sig(0x212, 39, 12, scale: 0.125, sna: 4095),
  // ID472 BMS_chargeInfo: what holds it back, as the car tells its owner.
  'chargeWhy': Sig(0x472, 32, 3),
  // ID333 UI_chargeRequest: the charge limit; ID33B: the minutes to it
  // (2047 none).
  'chargeLimit': Sig(0x333, 16, 10, scale: 0.1), // %
  'chargeMinutes': Sig(0x33B, 16, 11),
};

/// BMS_userChargeCurrentLimitMode in a word.
const kChargeWhy = {1: 'CHARGER', 2: 'COLD PACK', 3: 'FULL', 4: 'MOVE STALL'};

const kAutopilot = {
  2: 'AP READY',
  3: 'AUTOPILOT',
  4: 'AUTOPILOT',
  5: 'NAV ON AP',
  6: 'FSD',
  8: 'AP ENDING',
  9: 'AP ENDED',
  14: 'AP FAULT',
};

const kGears = {1: 'P', 2: 'R', 3: 'N', 4: 'D'};

/// Latch codes that mean "not shut": OPENED, OPENING, AJAR.
const kLatchOpen = {1, 4, 5};
const kRecirc = {0: 'AUTO', 1: 'RECIRC', 2: 'FRESH'};
const kDome = {0: 'OFF', 1: 'ON', 2: 'AUTO'};
const kFan2 = {0: 'AUTO', 1: 'OFF', 2: 'LOW', 3: 'MED', 4: 'HIGH'};

/// UI_hvacReqAutoBlowerLevel, how hard Auto runs the fans (one setting for
/// both rows; the DBC has no second-row level): the DBC's
/// five steps (VERY_LOW to VERY_HIGH) folded into the screen's Low, Medium
/// and High. ponytail: the fold is a guess until a log pairs the raw value
/// (Diagnostics' "auto") with the screen's setting.
const kAutoBlower = {0: 'LOW', 1: 'LOW', 2: 'MED', 3: 'HIGH', 4: 'HIGH'};

/// Every CAN id the dash needs — this is exactly what gets subscribed.
final kSubscribeIds = {...kSignals.values.map((s) => s.id)}.toList();

/// Extracts one signal from a frame's data bytes. Null when the frame is too
/// short, or when the car is reporting the signal as not available.
double? decode(Sig s, List<int> data) {
  if ((s.start + s.len + 7) ~/ 8 > data.length) return null;
  if (s.mux != null && _bits(data, s.muxStart, s.muxLen) != s.mux) return null;
  var v = _bits(data, s.start, s.len);
  if (v == s.sna) return null;
  if (s.signed && (v & (1 << (s.len - 1))) != 0) v -= 1 << s.len;
  return v * s.scale + s.offset;
}

int _bits(List<int> data, int start, int len) {
  var v = 0;
  for (var i = 0; i < len; i++) {
    final bit = start + i;
    if ((data[bit >> 3] >> (bit & 7)) & 1 == 1) v |= 1 << i;
  }
  return v;
}
