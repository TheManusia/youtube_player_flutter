import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:youtube_player_iframe/src/enums/player_state.dart';
import 'package:youtube_player_iframe/src/enums/youtube_error.dart';
import 'package:youtube_player_iframe/src/helpers/player_fragments.dart';
import 'package:youtube_player_iframe/src/meta_data.dart';

import '../controller.dart';
import '../enums/player_state.dart';
import '../enums/youtube_error.dart';

class RawWindowsYoutubePlayer extends StatefulWidget {
  /// The [YoutubePlayerController].
  final YoutubePlayerController controller;

  /// Which gestures should be consumed by the youtube player.
  ///
  /// It is possible for other gesture recognizers to be competing with the player on pointer
  /// events, e.g if the player is inside a [ListView] the [ListView] will want to handle
  /// vertical drags. The player will claim gestures that are recognized by any of the
  /// recognizers on this list.
  ///
  /// By default vertical and horizontal gestures are absorbed by the player.
  /// Passing an empty set will ignore the defaults.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  /// Creates a [RawYoutubePlayer] widget.
  const RawWindowsYoutubePlayer({
    Key? key,
    required this.controller,
    this.gestureRecognizers,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() => _WindowsYoutubePlayer();
}

class _WindowsYoutubePlayer extends State<RawWindowsYoutubePlayer> {
  late final WebviewController _webcontroller;
  late final YoutubePlayerController controller;

  @override
  void initState() {
    super.initState();

    _webcontroller = WebviewController();
    controller = widget.controller;
    init();
  }

  @override
  void dispose() {
    super.dispose();
    _webcontroller.dispose();
  }

  Future<void> init() async {
    await _webcontroller.initialize();
    await _webcontroller.setBackgroundColor(Colors.transparent);
    await _webcontroller.loadStringContent(player).then((value) {
      if (_webcontroller.value.isInitialized) {
        controller.invokeJavascript = _callMethod;
      }
    });
    await _webcontroller.webMessage.listen(
      (data) {
        if (_webcontroller.value.isInitialized) {
          if (data.containsKey('Ready')) {
            controller.add(
              controller.value.copyWith(isReady: true),
            );
          }

          if (data.containsKey('StateChange')) {
            switch (data['StateChange'] as int) {
              case -1:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.unStarted,
                    isReady: true,
                  ),
                );
                break;
              case 0:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.ended,
                  ),
                );
                break;
              case 1:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.playing,
                    hasPlayed: true,
                    error: YoutubeError.none,
                  ),
                );
                break;
              case 2:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.paused,
                  ),
                );
                break;
              case 3:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.buffering,
                  ),
                );
                break;
              case 5:
                controller.add(
                  controller.value.copyWith(
                    playerState: PlayerState.cued,
                  ),
                );
                break;
              default:
                throw Exception("Invalid player state obtained.");
            }
          }

          if (data.containsKey('PlaybackQualityChange')) {
            controller.add(
              controller.value.copyWith(playbackQuality: data['PlaybackQualityChange'] as String),
            );
          }

          if (data.containsKey('PlaybackRateChange')) {
            final rate = data['PlaybackRateChange'] as num;
            controller.add(
              controller.value.copyWith(playbackRate: rate.toDouble()),
            );
          }

          if (data.containsKey('Errors')) {
            controller.add(
              controller.value.copyWith(error: errorEnum(data['Errors'] as int)),
            );
          }

          if (data.containsKey('VideoData')) {
            controller.add(
              controller.value.copyWith(metaData: YoutubeMetaData.fromRawData(data['VideoData'])),
            );
          }

          if (data.containsKey('VideoTime')) {
            final position = data['VideoTime']['currentTime'] as double?;
            final buffered = data['VideoTime']['videoLoadedFraction'] as num?;

            if (position == null || buffered == null) return;
            controller.add(
              controller.value.copyWith(
                position: Duration(milliseconds: (position * 1000).floor()),
                buffered: buffered.toDouble(),
              ),
            );
          }
        }
      },
    );

    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(key: ValueKey(controller.hashCode), child: Webview(_webcontroller));
  }

  Future<void> _callMethod(String function) async {
    debugPrint(function);
    if (_webcontroller.value.isInitialized) await _webcontroller.executeScript(function);
  }

  String get player => '''
    <!DOCTYPE html>
    <body>
         ${youtubeIFrameTag(controller)}
        <script>
            $initPlayerIFrame
            var player;
            var timerId;
            function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                    events: {
                      onReady: (event) => sendMessage({ 'Ready': true }),
                      onStateChange: (event) => sendPlayerStateChange(event.data),
                      onPlaybackQualityChange: (event) => sendMessage({ 'PlaybackQualityChange': event.data }),
                      onPlaybackRateChange: (event) => sendMessage({ 'PlaybackRateChange': event.data }),
                      onError: (error) => sendMessage({ 'Errors': event.data }),
                    },
                });
            }
            
            window.chrome.webview.addEventListener('message', function(event) {
               try { eval(event.data) } catch (e) {}
            }, false);
            
            function sendMessage(message) {
               window.chrome.webview.postMessage(message);
            }

            function sendPlayerStateChange(playerState) {
                clearTimeout(timerId);
                sendMessage({ 'StateChange': playerState });
                if (playerState == 1) {
                    startSendCurrentTimeInterval();
                    sendVideoData(player);
                }
            }

            function sendVideoData(player) {
                var videoData = {
                    'duration': player.getDuration(),
                    'title': player.getVideoData().title,
                    'author': player.getVideoData().author,
                    'videoId': player.getVideoData().video_id
                };
                sendMessage({ 'VideoData': videoData });
            }

            function startSendCurrentTimeInterval() {
                timerId = setInterval(function () {
                  var videoTime = {
                      'currentTime': player.getCurrentTime(),
                      'videoLoadedFraction': player.getVideoLoadedFraction()
                  };
                  sendMessage({ 'VideoTime': videoTime });
                }, 100);
            }
            $youtubeIFrameFunctions
        </script>
    </body>
  ''';
}
