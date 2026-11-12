# audio_fx

Local plugin for the music player. On Android it attaches to the player's
audio session and provides:

- a 10-band graphic equalizer with preamp (`DynamicsProcessing`, Android 9+),
- a loudness gain for volume normalisation, with a limiter to prevent clipping,
- an FFT spectrum stream for the visualizer (`Visualizer`, needs RECORD_AUDIO).
