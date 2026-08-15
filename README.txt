OPL3.R4D
========

OPL3-SynthEngine-Treiber fuer R4OS.

Ziel:
- gueltige OPL3.R4D-Datei erzeugen
- Treibertyp synth verwenden
- aus Zig ueber Code/System/SDK/r4os und Code/build.zig bauen
- seit 0.45.20 DriverApi-v12 `register_synth_engine_v2` ueber den
  SDK-Wrapper `registerSynthEngineEx` aufrufen
- den externen OPL3-SynthEngine-Descriptor im Audio-Core aktivieren

Seit 0.4.80:
- Der Treiber registriert den Namen OPL3. Der Audio-Core erkennt diesen Namen
  und erwartet einen SynthEngine-Pfad.
- MIDI-Tests koennen OPL3 ueber midi_open_synth("OPL3") verwenden.

Seit 0.45.20:
- Der Treiber registriert einen strukturierten SynthEngine-Descriptor mit
  MIDI-/Render-/Stop-/Status- und OPL3-Operationsslots statt eines
  Markerzeigers.

Seit 0.45.22:
- Das OPL3-Registermodell, MIDI-zu-OPL3-Patchrouting und der Renderblock
  liegen in diesem Treiber unter `src/engine.zig`.
- `Code/Kernel/audio/opl3.zig` ist aus dem Kernel entfernt.
- Der Kernel-Audio-Core bleibt nur Bruecke fuer R4AUDIO, R4P-Klassifikation,
  SynthEngine-Registry und Status; OPL3-Reset, Registerwrites, MIDI-Events,
  Render und Stop laufen ueber `OPL3.R4D`.

Build:

    cd Code
    ..\DevTools\Zig\zig.exe build

Ausgabe:

    Code/zig-out/OPL3.R4D

Projektstruktur seit 0.51.22
--------------------------------

Dieses Verzeichnis ist ein eigenstaendiges R4OS-SDK-Projekt fuer OPL3.R4D.

Build:

    cd Code\System\Driver\OPL3
    ..\..\..\DevTools\Zig\zig.exe build

Artefakt:

    zig-out\OPL3.R4D

Manifest:

    module.R4MF

Image-Zielpfad: C:\R4OS\DRIVERS\OPL3.R4D
