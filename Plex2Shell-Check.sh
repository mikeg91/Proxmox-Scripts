#!/usr/bin/env bash
# plex2shell-check.sh — Plex2Shell IOC sweep. Run as root inside the Plex LXC.
# From the PVE host:  pct exec <CTID> -- bash -s < plex2shell-check.sh
set -uo pipefail

PMS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
FIXED="1.43.3.10861"
NAMES='myawesomeproxy|mylovelyminer|x12345|xmrig'
IPS='45\.194\.92\.222|91\.92\.40\.202|176\.65\.139\.228|217\.60\.194\.116'
HASHES='5712ef510481f15fe8b18fdd10b73026d57cb3d9d151878a692358b99a464441
68938fb428f2bcfef4ede62f7b29cd0f15f37ed59e94462c099f2ca64e36baa7
b20f39fc00d242e706b6c30367ad811c676e0575050a4ec2f30104b696944b49
e546b10aee5edc754da4f9b0baace00392257121911f630145078eafad1e6bd9
2d3c618b21a7e2f8bcd735da188e44a7609ff3f204832dd0781cd09e4388c9db'

hits=0
bad() { echo "  [!] $*"; hits=$((hits+1)); }
hdr() { printf '\n== %s\n' "$*"; }

hdr "Version"
ver=$(dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null)
echo "  plexmediaserver ${ver:-not installed via apt}"
[[ -n $ver ]] && dpkg --compare-versions "$ver" lt "$FIXED" && bad "Vulnerable (< $FIXED)"

hdr "Processes (plex user, by CPU)"
pgrep -af "$NAMES" && bad "Known Plex2Shell process running"
ps -u plex -o pid,ppid,etime,%cpu,args --sort=-%cpu | head -n 15

hdr "Payload files"
find / /dev/shm -xdev -type f \( -name myawesomeproxy -o -name mylovelyminer -o -name x12345 -o -name xmrig \) 2>/dev/null \
  | grep . && bad "Known payload filename on disk"
# Plex-owned files outside its data dir (skipping image/metadata stores) + all codec .so files,
# hashed against known samples
while IFS= read -r -d '' f; do
  grep -qx "$(sha256sum "$f" | cut -d' ' -f1)" <<<"$HASHES" && bad "Known malware hash: $f"
  [[ $f != "$PMS"/* ]] && echo "  plex-owned file outside data dir: $f"
done < <(find / /dev/shm -xdev \( -path "$PMS" -o -name Cache -o -name Metadata -o -name Media \) -prune \
              -o -type f -user plex -print0 2>/dev/null
         find "$PMS/Codecs" -type f -name '*.so' -print0 2>/dev/null)

hdr "Codecs .so, newest first (each should line up with a Plex update)"
find "$PMS/Codecs" -type f -name '*.so' -printf '  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -n 15

hdr "Preferences.xml"
grep -o 'TranscoderH264Options="[^"]*"' "$PMS/Preferences.xml" && bad "TranscoderH264Options set (did you set this?)"

hdr "Network"
ss -tnp | grep -E "$IPS" && bad "Live connection to known attacker IP"

hdr "Logs (Plex keeps few rotations — no hit is not proof of clean)"
grep -hE '/player/timeline/subscribe.*protocol=|sslip\.io|nip\.io|proxystream' "$PMS/Logs/"*.log* 2>/dev/null \
  | cut -c1-200 | tail -n 20 | grep . && bad "Exploit-pattern requests in logs"

hdr "Persistence"
crontab -u plex -l 2>/dev/null && bad "plex user has a crontab"
find /etc/cron* /etc/systemd /etc/profile.d /usr/local/bin /root/.ssh /var/lib/plexmediaserver/.config \
     -maxdepth 4 -type f -newermt 2026-10-15 2>/dev/null | sed 's/^/  changed since 10-15: /'
ls -la /var/lib/plexmediaserver/.{bashrc,profile,bash_profile} 2>/dev/null

hdr "Result"
((hits)) && echo "  $hits indicator(s) — treat the container as compromised." \
         || echo "  No known IOCs found (not proof of clean)."
