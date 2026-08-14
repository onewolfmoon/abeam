Abeam
=====

Screen mirroring
----------------

Screen mirroring is based on ScreenCaptureKit. Not all platforms supported by
Abeam have ScreenCaptureKit available, so screen mirroring is conditionally
compiled out with macros of the following form.

    #if canImport(ScreenCaptureKit)

ScreenCaptureKit is only available on the following:
* macOS. All versions of macOS supported by this app support ScreenCaptureKit.
* Physical iOS 27+ devices. Simulators are not supported.
