# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# synthv1 1.5.1, with the scheduler teardown fix that rncbc/synthv1 merged after it (#27, merge commit 893c6e5). Fedora ships
# 0.9.91 only. Without the fix, freeing an instance while the shared scheduler thread still runs one of its
# schedulers aborts the host. The packages keep Fedora's names, synthv1 and lv2-synthv1, and the Release sorts above
# Fedora's and above a stock 1.5.1-1, so dnf upgrades them in place. Drop the patch at the first upstream release
# that contains 893c6e5.

%global namespace org.rncbc

Name: synthv1
Version: 1.5.1
Release: 1.omx%{?dist}
Summary: A 4-oscillator subtractive polyphonic synthesizer
License: GPL-2.0-or-later
URL: https://%{name}.sourceforge.io/
Source0: https://github.com/rncbc/%{name}/archive/refs/tags/v%{version}/%{name}-%{version}.tar.gz
# Fedora's: keep the binaries unstripped so debuginfo is made
Patch0: %{name}-nostrip.patch
# rncbc/synthv1#27, merged upstream as 893c6e5b6ddc9b0bb505f00230cd68f5e7023025
Patch1: %{name}-893c6e5-sched-teardown.patch

BuildRequires: cmake
BuildRequires: gcc-c++
BuildRequires: cmake(Qt6Core)
BuildRequires: cmake(Qt6Gui)
BuildRequires: cmake(Qt6Widgets)
BuildRequires: cmake(Qt6Xml)
BuildRequires: cmake(Qt6LinguistTools)
BuildRequires: cmake(Qt6Svg)
BuildRequires: pkgconfig(alsa)
BuildRequires: pkgconfig(jack)
BuildRequires: pkgconfig(liblo)
BuildRequires: pkgconfig(lv2)
BuildRequires: desktop-file-utils
BuildRequires: libappstream-glib
Requires: hicolor-icon-theme

%description
%{name} is a 4-oscillator subtractive polyphonic synthesizer with stereo fx.

%package -n lv2-%{name}
Summary: An LV2 port of %{name}
Requires: lv2 >= 1.8.1

%description -n lv2-%{name}
An LV2 plugin of %{name}.

%prep
%autosetup -p1

%build
# 1.5.1 looks for libjack.so in pkg-config's libdir; pipewire-jack keeps it in its -L directory
jack_lib=$(find $(pkg-config --libs-only-L jack | sed 's/-L//g') %{_libdir} -maxdepth 1 -name libjack.so | head -n 1)
%cmake -DJACK_LIBRARY="$jack_lib"
%cmake_build

%install
%cmake_install
chmod +x %{buildroot}%{_libdir}/lv2/%{name}.lv2/%{name}.so

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{namespace}.%{name}.desktop
appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/%{namespace}.%{name}.metainfo.xml

%files
%doc README
%license LICENSE
%{_datadir}/applications/%{namespace}.%{name}.desktop
%{_datadir}/icons/hicolor/*/*/*
%{_bindir}/%{name}_jack
%{_datadir}/mime/packages/%{namespace}.%{name}.xml
%{_mandir}/man1/%{name}.1*
%{_mandir}/fr/man1/%{name}.1*
%{_metainfodir}/%{namespace}.%{name}.metainfo.xml
%{_datadir}/%{name}

%files -n lv2-%{name}
%doc README
%license LICENSE
%{_libdir}/lv2/%{name}.lv2/

%changelog
* Wed Nov 11 2026 Pau Aliagas <linuxnow@gmail.com> - 1.5.1-1.omx
- 1.5.1, with the scheduler teardown fix merged upstream as 893c6e5
