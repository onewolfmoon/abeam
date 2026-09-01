The problem
===========

You found something you want to watch. But you found it on your phone or your laptop.

You want to see it on your TV.

# Watch it on your TV with Abeam

Abeam is an app for your iPhone, iPad, and Mac that does two things:

- Show a video on your TV.
- Mirror your screen to your TV.

It does this with the help of a companion app called Abeam Receiver running on a Mac connected to your TV.

# How it works

## Set things up

Abeam runs on macOS 26 Tahoe and iOS/iPadOS 27. [Get it from the App Store.](https://apps.apple.com/us/app/abeam/id6798954537)

Abeam Receiver runs on macOS 13 Ventura. [Get it from GitHub.](https://github.com/onewolfmoon/abeam/releases/latest) If your drawer has a dusty MacBook (~2017 or newer), now’s the time to take it out of retirement and hook it up to your TV. You may need a USB-C–HDMI adapter.

## Send a video

Copy a URL or use the Share button in your favourite streaming app and watch it on your TV.

The app doesn’t need any built-in support for AirPlay or Google Cast.

## Share your screen

Open Abeam and go for it.

# Why not [AirPlay](https://www.apple.com/airplay/) or [Google Cast](https://www.android.com/better-together/google-cast/)

If they work for you, you should use them. They’re built into your phone or computer, and they work great within their ecosystem.

I wrote Abeam because I ran into too many little issues with each of them. If you’re curious, you can check out the [list of papercuts](docs/papercuts.md) I ran into.

Contributing
============

Please help implement support for more services. Here's how you can help:

1. Tap the Share button in your unsupported sharing service and create a Note with the result. Copy that text and file it as a GitHub issue in this repository.

    Self-promotion: Need to move that text to your computer? Try [Degap](https://degap.app/).

2. Know how to code? Send me a pull request with a VideoParser for the service (in `//Abaft/VideoParsers`).
