The problem
===========

You've found something you want to watch on your phone or laptop.

You want to see it on your TV.

Your options in 2026:

* **AirPlay:** Can't use your phone for anything else while AirPlaying. Sometimes TV audio level is tied to phone volume.
* **AirPlay screen mirroring:** Slow with heavy artifacting. The New York Times crossword is unplayable. Can't cast a single window.
* **Chromecast classic:** Barely supported. Some YouTube videos silently refuse to play.
* **Chromecast with Google TV:** Often needs you to press a button on its remote to start playback.
* **Chromecast screen mirroring:** Can't cast the screen with audio.

Abeam
=====

Abeam is an app for your iPhone and Mac that helps you do two things:

1. Put a video on your TV by URL.
2. Mirror your screen to your TV.

Send a video
------------

Use the Share button in your video streaming app to send a video to your screen. Chromecast and AirPlay support does not need to be built into the streaming app.

Currently supported services:

* YouTube
* Dropout

Any other link is shown as a full-screen web page rather than full-screen video, since Abaft doesn't know whether or where the page has a video to play.

**Seeking contributors:** Please help implement support for more services. Here's how you can help:

1. Tap the Share button in your unsupported sharing service and create a Note with the result. Copy that text and file it as a GitHub issue in this repository.

    Self-promotion: Need to move that text to your computer? Try [Degap](https://degap.app/).

2. Know how to code? Send me a pull request with a VideoParser for the service (in `//Abaft/VideoParsers`).

Screen mirroring
----------------

Screen mirroring is based on ScreenCaptureKit. Not all platforms supported by
Abeam have ScreenCaptureKit available, so screen mirroring is conditionally
compiled out with macros of the following form.

    #if canImport(ScreenCaptureKit)

ScreenCaptureKit is only available on the following:
* macOS. All versions of macOS supported by this app support ScreenCaptureKit.
* Physical iOS 27+ devices. Simulators are not supported.

Abaft
=====

Abeam has a companion app called Abaft that runs on a Mac connected to your TV. Abaft shows the videos you send or your mirrored screen full screen.

For sending videos, Abaft works like a web browser. Log in and dismiss cookie banners directly in Abaft from your keyboard and mouse, then put your peripherals away.

Contributing
============

This project is licensed under the Mozilla Public License. To contribute to this project, code you write will also be licensed under the MPL 2.0.

I don’t ask you to sign a copyright assignment to contribute to this project. This prevents me or a future maintainer from relicensing this project in the future without getting your permission or replacing the code you wrote entirely (i.e. an open source rug pull).

I chose the MPL for this project to require derivative projects to also share the source code of any parts of this project they use. Because this codebase contains code for apps that are intended to be distributed through app stores, the GNU Public License may be incompatible, and I’ve labeled this code as _Incompatible With Secondary Licenses_. See Exhibit B in LICENSE.
