# zaudio

A small, dependency-free audio reading library for **Zig 0.16.0**.

## Quick start

```sh
zig build
zig build run -- path/to/audio.wav
```

## Roadmap

The goal is to support the audio containers, streams, and codecs supported by FFmpeg.

- [ ] create man pages
- [ ] write unit tests

### WAV container (currently in progress)

- [ ] RF64.
- [ ] BW64.
- [ ] RIFX.
- [ ] Wave64.
- [ ] Segmented audio.

### Decoder support

- [ ] Codec packet framing and codec configuration.
- [ ] Compressed block decoding across reads.
- [ ] Codec state reset and seeking.
- [ ] Decoder delay and trailing sample trimming.
- [ ] Channel mapping and sample conversion.

### Lossy codecs

- [ ] AAC.
- [ ] AAC LATM.
- [ ] AC3.
- [ ] ADU MP3.
- [ ] aptX.
- [ ] aptX HD.
- [ ] ATRAC1.
- [ ] ATRAC3.
- [ ] ATRAC3 plus.
- [ ] ATRAC9.
- [ ] Cook, Cooker, Gecko.
- [ ] DTS.
- [ ] EAC3.
- [ ] IAC.
- [ ] IMC.
- [ ] LC3.
- [ ] MACE 3 to 1.
- [ ] MACE 6 to 1.
- [ ] MP1.
- [ ] MP2.
- [ ] MP3.
- [ ] MP3onMP4.
- [ ] MPEG H 3D Audio.
- [ ] Musepack SV7.
- [ ] Musepack SV8.
- [ ] Nellymoser Asao.
- [ ] On2 Audio for Video Codec.
- [ ] Opus.
- [ ] QDesign Music.
- [ ] QDesign Music Codec 2.
- [ ] SBC.
- [ ] Vorbis.
- [ ] Voxware MetaSound.
- [ ] VQF TwinVQ.
- [ ] Windows Media Audio 1.
- [ ] Windows Media Audio 2.
- [ ] Windows Media Audio 9 Professional.

### Lossless codecs

- [ ] ALAC.
- [ ] ATRAC3 Advanced Lossless.
- [ ] ATRAC3 plus Advanced Lossless.
- [ ] Bonk audio.
- [ ] DST.
- [ ] FLAC.
- [ ] Marian A pac audio.
- [ ] MLP.
- [ ] Monkeys Audio.
- [ ] MPEG 4 ALS.
- [ ] OSQ.
- [ ] RealAudio Lossless.
- [ ] RKA.
- [ ] Shorten.
- [ ] TAK.
- [ ] TrueHD.
- [ ] TTA.
- [ ] Waveform Archiver.
- [ ] WavPack.
- [ ] Windows Media Audio Lossless.

### Speech codecs

- [ ] A law.
- [ ] AMR NB.
- [ ] AMR WB.
- [ ] Codec2.
- [ ] Digital Speech Standard Standard Play mode.
- [ ] DSP Group TrueSpeech.
- [ ] EVRC.
- [ ] FTR Voice.
- [ ] G.723.1.
- [ ] G.728.
- [ ] G.729.
- [ ] GSM.
- [ ] GSM Microsoft variant.
- [ ] iLBC.
- [ ] MSN Siren.
- [ ] Mu law.
- [ ] QCELP, PureVoice.
- [ ] RealAudio 14.4.
- [ ] RealAudio 28.8.
- [ ] RealAudio SIPR, ACELP.NET.
- [ ] RFC 3389 Comfort Noise.
- [ ] Sipro ACELP.KELVIN.
- [ ] Siren.
- [ ] Speex.
- [ ] Windows Media Audio Voice.

### Additional PCM and DSD encodings

- [ ] DSD least significant bit first.
- [ ] DSD most significant bit first.
- [ ] DSD planar least significant bit first.
- [ ] DSD planar most significant bit first.
- [ ] DV audio.
- [ ] PCM 16.8 floating point little endian.
- [ ] PCM 24.0 floating point little endian.
- [ ] PCM Archimedes VIDC.
- [ ] PCM D Cinema audio signed 24 bit.
- [ ] PCM SGA.
- [ ] PCM signed 16 bit big endian planar.
- [ ] PCM signed 16 bit little endian planar.
- [ ] PCM signed 16, 20, 24 bit big endian for Blu ray media.
- [ ] PCM signed 16, 20, 24 bit big endian for DVD Audio media.
- [ ] PCM signed 16, 20, 24 bit big endian for DVD Video media.
- [ ] PCM signed 20 bit little endian planar.
- [ ] PCM signed 24 bit little endian planar.
- [ ] PCM signed 32 bit little endian planar.
- [ ] PCM signed 8 bit planar.
- [ ] PCM unsigned 16 bit big endian.
- [ ] PCM unsigned 16 bit little endian.
- [ ] PCM unsigned 24 bit big endian.
- [ ] PCM unsigned 24 bit little endian.
- [ ] PCM unsigned 32 bit big endian.
- [ ] PCM unsigned 32 bit little endian.
- [ ] SMPTE 302M.

### ADPCM codecs

- [ ] ADPCM 4X Movie.
- [ ] ADPCM AmuseGraphics Movie AGM.
- [ ] ADPCM Argonaut Games.
- [ ] ADPCM CDROM XA.
- [ ] ADPCM Circus.
- [ ] ADPCM Creative Technology.
- [ ] ADPCM Electronic Arts.
- [ ] ADPCM Electronic Arts Maxis CDROM XA.
- [ ] ADPCM Electronic Arts R1.
- [ ] ADPCM Electronic Arts R2.
- [ ] ADPCM Electronic Arts R3.
- [ ] ADPCM Electronic Arts XAS.
- [ ] ADPCM IMA Acorn Escape.
- [ ] ADPCM IMA Acorn Replay.
- [ ] ADPCM IMA AMV.
- [ ] ADPCM IMA Capcom MT Framework.
- [ ] ADPCM IMA CRYO APC.
- [ ] ADPCM IMA Cunning Developments.
- [ ] ADPCM IMA Dialogic OKI.
- [ ] ADPCM IMA Duck DK3.
- [ ] ADPCM IMA Duck DK4.
- [ ] ADPCM IMA Electronic Arts EACS.
- [ ] ADPCM IMA Electronic Arts SEAD.
- [ ] ADPCM IMA Eurocom DAT4.
- [ ] ADPCM IMA Funcom ISS.
- [ ] ADPCM IMA High Voltage Software ALP.
- [ ] ADPCM IMA HVQM2.
- [ ] ADPCM IMA HVQM4.
- [ ] ADPCM IMA Loki SDL MJPEG.
- [ ] ADPCM IMA Magix.
- [ ] ADPCM IMA MobiClip MOFLEX.
- [ ] ADPCM IMA PlayDate.
- [ ] ADPCM IMA QuickTime.
- [ ] ADPCM IMA Radical.
- [ ] ADPCM IMA Simon and Schuster Interactive.
- [ ] ADPCM IMA Ubisoft APM.
- [ ] ADPCM IMA WAV.
- [ ] ADPCM IMA Westwood.
- [ ] ADPCM IMA Xbox.
- [ ] ADPCM Konami XMD.
- [ ] ADPCM Microsoft.
- [ ] ADPCM MTAF.
- [ ] ADPCM Nintendo Gamecube AFC.
- [ ] ADPCM Nintendo Gamecube DTK.
- [ ] ADPCM Nintendo THP big endian.
- [ ] ADPCM Nintendo THP little endian.
- [ ] ADPCM Playstation.
- [ ] ADPCM Playstation C.
- [ ] ADPCM Rhetorex.
- [ ] ADPCM Sanyo.
- [ ] ADPCM Shockwave Flash.
- [ ] ADPCM Silicon Graphics N64.
- [ ] ADPCM Sound Blaster Pro 2 bit.
- [ ] ADPCM Sound Blaster Pro 2.6 bit.
- [ ] ADPCM Sound Blaster Pro 4 bit.
- [ ] ADPCM Yamaha.
- [ ] ADPCM Yamaha AICA.
- [ ] ADPCM Zork.
- [ ] G.722 ADPCM.
- [ ] G.726 ADPCM.
- [ ] G.726 ADPCM little endian.
- [ ] LucasArts VIMA audio.
- [ ] SEGA CRI ADX ADPCM.

### DPCM codecs

- [ ] 8SVX exponential.
- [ ] 8SVX Fibonacci.
- [ ] DPCM Cuberoot Delta Exact.
- [ ] DPCM Gremlin.
- [ ] DPCM id RoQ.
- [ ] DPCM Interplay.
- [ ] DPCM Marble WADY.
- [ ] DPCM Sol.
- [ ] DPCM Squareroot Delta Exact.
- [ ] DPCM Xan.
- [ ] DPCM Xilam DERF.

### Other codecs

- [ ] Amazing Studio Packed Animation File Audio.
- [ ] Bink Audio DCT.
- [ ] Bink Audio RDFT.
- [ ] CRI AHX.
- [ ] CRI HCA.
- [ ] Delphine Software International CIN audio.
- [ ] DFPWM.
- [ ] Discworld II BMV audio.
- [ ] Dolby E.
- [ ] HCOM Audio.
- [ ] Interplay ACM.
- [ ] Micronas SC 4 Audio.
- [ ] MobiClip FastAudio.
- [ ] QOA.
- [ ] Sierra VMD audio.
- [ ] Smacker audio.
- [ ] Westwood Audio.
- [ ] Xbox Media Audio 1.
- [ ] Xbox Media Audio 2.

### Common audio containers and streams

- [ ] MP3 streams.
- [ ] MP1 streams.
- [ ] MP2 streams.
- [ ] ADTS.
- [ ] LOAS.
- [ ] FLAC.
- [ ] M4A.
- [ ] AIFF.
- [ ] AIFC.
- [ ] CAF.
- [ ] AU.
- [ ] WMA files.
- [ ] Monkeys Audio.
- [ ] WavPack.
- [ ] TTA.
- [ ] TAK.
- [ ] Shorten.
- [ ] Musepack SV7.
- [ ] Musepack SV8.
- [ ] TwinVQ VQF.
- [ ] Sony OpenMG.
- [ ] AMR.
- [ ] DSF.
- [ ] IFF 8SVX.
- [ ] DSDIFF.
- [ ] IAMF.
- [ ] Raw PCM with caller supplied format.

### Raw compressed streams

- [ ] Raw AC3.
- [ ] Raw EAC3.
- [ ] Raw AC4.
- [ ] Raw DTS.
- [ ] DTS HD streams.
- [ ] Raw MLP.
- [ ] Raw TrueHD.
- [ ] Raw AMR NB.
- [ ] Raw AMR WB.
- [ ] Raw aptX.
- [ ] Raw aptX HD.
- [ ] Raw Bonk.
- [ ] Raw DFPWM1a.
- [ ] Raw G.722.
- [ ] G.723.1.
- [ ] Raw G.726 big endian.
- [ ] Raw G.726 little endian.
- [ ] Raw G.728.
- [ ] Raw G.729.
- [ ] Raw GSM.
- [ ] iLBC storage.
- [ ] LC3.
- [ ] Codec2 C2.
- [ ] Raw Codec2.
- [ ] Raw APAC.
- [ ] Raw OSQ.
- [ ] QOA.

### Other audio containers

- [ ] ADP.
- [ ] AFC.
- [ ] Argonaut Games ASF.
- [ ] Argonaut Games CVG.
- [ ] AST.
- [ ] Asterisk SLN.
- [ ] Audible AA format files.
- [ ] AVR.
- [ ] BFSTM.
- [ ] Bink Audio.
- [ ] Black Ops Audio.
- [ ] BRSTM.
- [ ] Capcom MT Framework sound.
- [ ] Creative VOC.
- [ ] CRI AAX.
- [ ] CRI ADX.
- [ ] CRI AIX.
- [ ] CRI HCA.
- [ ] CRYO APC.
- [ ] D Cinema audio.
- [ ] Digital Speech Standard.
- [ ] Electronic Arts cdata.
- [ ] Ensoniq Paris Audio File.
- [ ] Eurocom MUSX.
- [ ] FMOD Sample Bank.
- [ ] Funcom ISS.
- [ ] G.729 BIT file format.
- [ ] GameCube RSD.
- [ ] GENeric Header.
- [ ] IEC 61937 compressed audio.
- [ ] Interplay ACM.
- [ ] IRCAM.
- [ ] Konami PS2 MTAF.
- [ ] Konami PS2 SVAG.
- [ ] Konami XMD.
- [ ] LAF.
- [ ] Lego Mindstorms RSO.
- [ ] LEGO Racers ALP.
- [ ] Macintosh HCOM.
- [ ] Marble WADY.
- [ ] Maxis XA.
- [ ] MCA Audio Format.
- [ ] MD STUDIO audio.
- [ ] MIDI Sample Dump Standard.
- [ ] NIST SPHERE.
- [ ] NSP.
- [ ] Pro Pinball Series Soundbank.
- [ ] Psion 3 audio.
- [ ] PVF.
- [ ] QCP.
- [ ] RedSpark.
- [ ] RKA.
- [ ] Sample Dump eXchange.
- [ ] Sega DC STR.
- [ ] Sierra SOL.
- [ ] Simon and Schuster Interactive VAG.
- [ ] SMPTE 337M.
- [ ] Sony PS2 ADS.
- [ ] Sony PS2 VAG.
- [ ] Sony PS2 VPK.
- [ ] Sony PS3 MSF.
- [ ] Sony PS3 XVAG.
- [ ] SoX native.
- [ ] Square Enix SCD.
- [ ] Square SVS.
- [ ] tri Ace Audio Container.
- [ ] Ubisoft Rayman 2 APM.
- [ ] Waveform Archiver.
- [ ] Westwood Studios audio.
- [ ] Wideband Single bit Data.
- [ ] Xbox SDNS.
- [ ] Xilam DERF.
- [ ] XWMA.
