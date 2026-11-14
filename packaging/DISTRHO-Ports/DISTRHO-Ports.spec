# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Audinux's DISTRHO-Ports (Fedora has it only from the ycollet/audinux copr), built from the same commit with its
# submodules (make-source.sh, as .github/pins.txt pins it), with one patch of ours: juced's parameter thread updates
# only parameters still alive, so DrumSynth and the other juced ports no longer abort when an instance is freed with
# changes queued (Open-Mixer/plugin-qualify#15). 1.1.0-4.1.omx sorts above the copr's 1.1.0-4.

# Status: active
# Tag: Guitar, Equalizer, Convolution, Amp Simul, Overdrive
# Type: Plugin, LV2
# Category: Audio, Synthesizer, Effect

%global commit0 43330739392197cd1b3b0df23b194879ddf68f23

Name: DISTRHO-Ports
Version: 1.1.0
Release: 4.1.omx%{?dist}
Summary: A set of LV2 plugins
License: GPL-2.0-or-later
URL: https://github.com/DISTRHO/DISTRHO-Ports
ExclusiveArch: x86_64 aarch64

Vendor:       Audinux
Distribution: Audinux

# made by make-source.sh from the commit above, with its submodules (JUCE), not a download
Source0: %{name}-%{commit0}.tar.gz
# Open-Mixer/plugin-qualify#15
Patch0:  DISTRHO-Ports-juced-live-parameters.patch

BuildRequires: gcc gcc-c++
BuildRequires: meson
BuildRequires: ladspa-devel
BuildRequires: liblo-devel
BuildRequires: alsa-lib-devel
BuildRequires: pulseaudio-libs-devel
BuildRequires: freetype-devel
BuildRequires: libXrandr-devel
BuildRequires: libXinerama-devel
BuildRequires: libXcursor-devel
BuildRequires: mesa-libGL-devel
BuildRequires: mesa-libGLU-devel
BuildRequires: fftw-devel

%description
A set of LV2 plugins
- SwankyAmp: tube amplifier simulation
- Vitalium: Synthesizer
- Chow: digital distortion effect. Useful for mixing guitars, drums, even vocals when a heavily degraded sound is desired
- TAL Dub-3, Filter, NoiseMaker, Reverb and Vocoder.
- KlangFalter: convolution audio plugin, e.g. for usage as convolution reverb.
- ...

%prep
%autosetup -p1 -n %{name}-%{commit0}

sed -i -e "s/,--strip-all//g" meson.build

%build

%set_build_flags
export LDFLAGS="`pkg-config --libs-only-L jack` $LDFLAGS"
export CFLAGS="-fpermissive $CFLAGS"
export CXXFLAGS="-fpermissive $CXXFLAGS"

%meson --debug -Dbuild-lv2=true -Dbuild-vst3=true
%meson_build

%install

%meson_install

%files
%doc README.md
%{_libdir}/lv2/*
%{_libdir}/vst/*
%{_libdir}/vst3/*

%changelog
* Wed Nov 11 2026 Pau Aliagas <linuxnow@gmail.com> - 1.1.0-4.1.omx
- juced: the parameter thread updates only parameters still alive (DrumSynth no longer aborts)

* Mon Mar 15 2021 Yann Collette <ycollette.nospam@free.fr> - 1.0.4-4
- update to 2021-03-15 (1.0.3)

* Fri Jan 15 2021 Yann Collette <ycollette.nospam@free.fr> - 1.0.3-4
- update to 2021-01-15 (1.0.3)

* Wed Dec 30 2020 Yann Collette <ycollette.nospam@free.fr> - 1.0.2-4
- update to 2020-12-27 (1.0.2)

* Fri Oct 23 2020 Yann Collette <ycollette.nospam@free.fr> - 1.0.1-4
- fix debug build

* Tue Jul 14 2020 Yann Collette <ycollette.nospam@free.fr> - 1.0.1-4
- update to 2020-07-14 (1.0.1)

* Wed Nov 6 2019 Yann Collette <ycollette.nospam@free.fr> - 1.0.0beta-4
- update to 7e62235e809e59770d0d91d2c48c3f50ce7c027a

* Mon Oct 15 2018 Yann Collette <ycollette.nospam@free.fr> - 1.0.0beta-3
- update for Fedora 29

* Sat May 12 2018 Yann Collette <ycollette.nospam@free.fr> - 1.0.0beta-3
- update to a82fff059baafc03f7c0e8b9a99f383af7bfbd79

* Mon Oct 23 2017 Yann Collette <ycollette.nospam@free.fr> - 1.0.0beta-2
- update to latest master

* Sat Jun 06 2015 Yann Collette <ycollette.nospam@free.fr> - 1.0.0beta
- Initial build
