# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# clap, the CLAP plugin API headers, at the commit of .github/pins.txt (tag 1.2.10): the floor every package of the
# channel builds against. Fedora 44 and 45 ship clap-devel 1.2.7, older than that floor; this package, a newer EVR
# of the same name, is what dnf installs from the channel. Debian carries none, and clap-headers-deb.yml builds the
# same pin there. Fedora's own spec (src.fedoraproject.org/rpms/clap) with the pinned commit for its Source. The
# package carries the suffix omx after its Release, as every package the channel rebuilds does.

# a header-only package: no debug symbols
%global debug_package %{nil}

%global commit0 195b42a004144fab0b3cf95e9c067187d15365b7

Name:           clap
Version:        1.2.10
Release:        1.omx%{?dist}
Summary:        Audio Plugin API
License:        MIT
URL:            https://github.com/free-audio/clap
Source0:        https://github.com/free-audio/clap/archive/%{commit0}/clap-%{commit0}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  cmake

%description
CLAP stands for CLever Audio Plugin. It is an interface that provides a stable
ABI to define a standard for Digital Audio Workstations and audio plugins
(synthesizers, audio effects, ...) to work together.

%package        devel
Summary:        Development files for CLAP
Provides:       %{name}-static = %{version}-%{release}

%description    devel
%{summary}.

%prep
%autosetup -n clap-%{commit0}

%build
%cmake
%cmake_build

%install
%cmake_install

%check
# the headers say the version this package carries
grep -q '#define CLAP_VERSION_MAJOR 1' %{buildroot}%{_includedir}/clap/version.h
grep -q '#define CLAP_VERSION_MINOR 2' %{buildroot}%{_includedir}/clap/version.h
grep -q '#define CLAP_VERSION_REVISION 10' %{buildroot}%{_includedir}/clap/version.h

%files devel
%license LICENSE
%doc README.md
%{_includedir}/clap/
%{_libdir}/cmake/clap/
%{_libdir}/pkgconfig/clap.pc

%changelog
* Fri Nov 13 2026 Pau Aliagas <linuxnow@gmail.com> - 1.2.10-1.omx
- The channel's clap 1.2.10, at the pin of .github/pins.txt, the CLAP floor of every package it serves; Fedora's
  spec with the pinned commit.
