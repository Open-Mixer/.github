# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Fedora's zita-convolver 4.0.3 (the library guitarix's convolution plugins link), with one patch of ours: a
# convolution level is running from the moment it is started, not from when its detached thread is first scheduled,
# so a stop and a cleanup that come before the thread runs wait for it instead of freeing what it then uses
# (Open-Mixer/plugin-qualify#29: gx_amp, gx_cabinet and gxmetal_head crashed in the lifecycle step at 192 kHz in
# 128-frame blocks). Upstream (kokkinizita.linuxaudio.org) is a tarball, not a git; .github/pins.txt pins the commit
# of a mirror whose source/ is that tarball byte for byte. 4.0.3-19.1.omx sorts above Fedora 45's 4.0.3-19 and
# Fedora 44's 4.0.3-18, so dnf replaces either in place.

%global commit0 930492863d7bdb7922fb7b587ccb8fb1290a1811

Summary:       Convolution engine library
Name:          zita-convolver
Version:       4.0.3
Release:       19.1.omx%{?dist}
License:       GPL-3.0-or-later
URL:           http://kokkinizita.linuxaudio.org/
Source0:       http://kokkinizita.linuxaudio.org/linuxaudio/downloads/%{name}-%{version}.tar.bz2
# Open-Mixer/plugin-qualify#29
Patch0:        zita-convolver-convlevel-running-from-start.patch

BuildRequires: make
BuildRequires: fftw-devel
BuildRequires: gcc-c++

%description
%{name} is a fast, partitioned convolution engine library.

%package  devel
Summary:       Fast, partitioned convolution engine library
Requires:      %{name}%{?_isa} = %{version}-%{release}
Requires:      fftw-devel

%description devel
%{name} is a fast, partitioned convolution engine library. This package
contains libraries and header files for developing applications that use
%{name}.

%prep
%setup -q
%patch -P0 -p1

# Preserve timestamps
sed -i 's|install |install -p |' source/Makefile

# No need to call ldconfig during packaging
sed -i '\|ldconfig|d' source/Makefile

sed -i '\|^CXXFLAGS += -march=native|d' source/Makefile

%build
%set_build_flags
%make_build -C source PREFIX=%{_prefix}

%install
%make_install -C source PREFIX=%{_prefix} LIBDIR=%{_libdir}

%files
%doc AUTHORS README
%license COPYING
%{_libdir}/lib%{name}.so.4*

%files devel
%{_includedir}/%{name}.h
%{_libdir}/lib%{name}.so

%changelog
* Fri Nov 13 2026 Pau Aliagas <linuxnow@gmail.com> - 4.0.3-19.1.omx
- Convlevel runs from start (), not from when its thread is first scheduled: a stop and a cleanup before that no
  longer free what the thread then uses (guitarix gx_amp, gx_cabinet, gxmetal_head at 192 kHz / 128 frames)

* Fri Jul 17 2026 Fedora Release Engineering <releng@fedoraproject.org> - 4.0.3-19
- Rebuilt for https://fedoraproject.org/wiki/Fedora_45_Mass_Rebuild

* Sat Jan 17 2026 Fedora Release Engineering <releng@fedoraproject.org> - 4.0.3-18
- Rebuilt for https://fedoraproject.org/wiki/Fedora_44_Mass_Rebuild
