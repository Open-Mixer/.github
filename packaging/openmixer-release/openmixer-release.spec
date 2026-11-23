# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The package that adds the OpenMixer repository to dnf, as rpmfusion-free-release does for RPM Fusion: a change
# of baseurl or key reaches every machine as an update of this package. Source1 is the key file the channel
# serves at rpm/RPM-GPG-KEY-openmixer, fetched at build time (build.sh); it is not kept in this repository.
# Version-Release is the release of debian/changelog too: build.sh refuses a build where the two differ.
Name:           openmixer-release
Version:        1
Release:        9%{?dist}
Summary:        OpenMixer package repository configuration for dnf
License:        MIT
URL:            https://www.openmixer.org
Source0:        openmixer.repo
Source1:        RPM-GPG-KEY-openmixer
BuildArch:      noarch
# OpenMixer installs reac-pw (floor only, in each package that needs it) and does not carry it: the FreeREAC repository that does comes with this package
Requires:       freereac-release >= 1-2

%description
Adds the OpenMixer repository, which carries the OpenMixer console and its plugin hosts, to dnf, with the
key that signs its packages and metadata. dnf update keeps this configuration current.

%prep

%build

%install
install -Dpm 0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/yum.repos.d/openmixer.repo
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-openmixer

%files
%config(noreplace) %{_sysconfdir}/yum.repos.d/openmixer.repo
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-openmixer

%changelog
* Mon Nov 23 2026 Pau Aliagas <linuxnow@gmail.com> - 1-9
- The testing repositories, openmixer-testing and openmixer-testing-noarch: the staging channel of the release wave, installed disabled, as Fedora's updates-testing; enabling them is the whole opt-in to the builds a wave proved before their release.

* Wed Nov 18 2026 Pau Aliagas <linuxnow@gmail.com> - 1-8
- The package of 1-7, released: the 1-7 run was refused by the installability gate, which read the FreeREAC channel without its noarch tree where freereac-release lives. Requires freereac-release >= 1-2: the floor the gate asks of every dependency between our own packages, now that this channel serves freereac-release (the mirror).

* Wed Nov 18 2026 Pau Aliagas <linuxnow@gmail.com> - 1-7
- Requires freereac-release: reac-pw comes from the FreeREAC channel, whose repository and one key that package installs.

* Wed Nov 18 2026 Pau Aliagas <linuxnow@gmail.com> - 1-6
- Ships exactly one key, the OpenMixer release signing key; the personal key and the retired release key are no longer shipped.

* Sun Nov 15 2026 Pau Aliagas <linuxnow@gmail.com> - 1-5
- Built and served for every Fedora release of the set: fc45 beside fc44 (the fc44 build alone was served before).

* Sun Nov 01 2026 Pau Aliagas <linuxnow@gmail.com> - 1-4
- Ships the channel's public keys with the new release signing key beside the old one.

* Mon Oct 26 2026 Pau Aliagas <linuxnow@gmail.com> - 1-3
- Released with the deb, which now serves Ubuntu from the trixie source; the repository file is unchanged.

* Mon Oct 26 2026 Pau Aliagas <linuxnow@gmail.com> - 1-2
- The first published release: the signing key id reaches the publish step.

* Mon Oct 26 2026 Pau Aliagas <linuxnow@gmail.com> - 1-1
- The OpenMixer repository, ids openmixer and openmixer-noarch, and its key
