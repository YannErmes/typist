/// One live tab-capture session for stream writing: after a single browser
/// pick, every frame note grabs exactly what the floating player shows
/// (cropped to its on-screen rect), with no further popups.
///
/// Web only ([live_capture_web.dart]); elsewhere this is a silent no-op
/// until a desktop capture path lands.
class LiveCapture {
  void Function()? onEnded;
  bool get live => false;
  Future<bool> start() async => false;
  void stop() {}
  Future<String?> grab(
      double cssX, double cssY, double cssW, double cssH) async {
    return null;
  }
}
