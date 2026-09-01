Contributing to Abeam
=====================

Thanks for your interest. The rest of this document describes what you need to know depending on what you want to contribute.

Requesting support for a streaming service
------------------------------------------

If you're using a streaming service that Abeam Receiver doesn't fully support, you might see some of the following behaviours:

* The video doesn't play in fullscreen.
* Play/pause/seek doesn't work.
* The window doesn't disappear when the video ends.

Here's what needs to happen to add support for that streaming service. Starting from step 1, please follow as many or as few of these steps as you feel comfortable doing.

1. File an issue in the Abeam repository for this streaming service.

    https://github.com/onewolfmoon/abeam/issues/new

    Make sure the issue title has the name of the streaming service, and label the issue "streaming service".

2. Post a sample URL or share payload in that issue.

    If you're watching the video on a computer, paste that URL into the GitHub issue. If you're using an iPhone, tap share, then share the resulting text somewhere where you can paste it into the GitHub issue. (Consider using Notes or [Degap](https://degap.app/).)

3. Implement a VideoParser for that service.

    These live in the VideoParsers package. Each parser should conform to the VideoParser protocol. Send me a pull request.

Contributing code
-----------------

Here's what you need to know:

1. Please submit code in the form of pull requests.

2. Abeam is licensed under MPL 2.0. Any code you contribute will also be licensed under MPL 2.0.

3. Sending valid, useful code is no guarantee that your change will be merged. Please get in touch before you begin if you're working on something big or just want to discuss whether a change would be welcome.

    That said, the codebase is open source. Friendly forks are welcome.

4. The language for comments and documentation in this repository is Canadian English.

You might also like to know:

* Why MPL 2.0: [docs/license.md](docs/license.md)
* Why the codebase is the way it is: [docs/wtfs.md](docs/wtfs.md)
* The protocol over which Abeam and Abaft communicate: [docs/protocol.md](docs/protocol.md)
