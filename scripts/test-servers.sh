#!/bin/bash
# Starts throwaway FTP and SSH servers on localhost for the live tests.
#   scripts/test-servers.sh <empty work folder> <python with pyftpdlib>
# Then, in another shell: MC_TEST_DIR=<work folder> swift test
# Only listens on 127.0.0.1 and only accepts the key it generates here.
set -euo pipefail

DIR="$1"
PY="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$DIR/root" "$DIR/ssh"
[ -f "$DIR/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=localhost" -keyout "$DIR/cert.pem" -out "$DIR/cert.pem" 2>/dev/null
[ -f "$DIR/ssh/host_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/ssh/host_key"
[ -f "$DIR/ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/ssh/id_ed25519"
cp "$DIR/ssh/id_ed25519.pub" "$DIR/ssh/authorized_keys"
chmod 600 "$DIR/ssh/authorized_keys"

write_config() {
  cat > "$DIR/ssh/sshd_$1.conf" <<EOF
Port $1
ListenAddress 127.0.0.1
HostKey $DIR/ssh/host_key
AuthorizedKeysFile $DIR/ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
UsePAM no
PidFile $DIR/ssh/sshd_$1.pid
$2
EOF
}
write_config 2222 "Subsystem sftp /usr/libexec/sftp-server"
write_config 2223 "# no sftp subsystem on purpose"

/usr/sbin/sshd -f "$DIR/ssh/sshd_2222.conf" -E "$DIR/ssh/sshd_2222.log"
/usr/sbin/sshd -f "$DIR/ssh/sshd_2223.conf" -E "$DIR/ssh/sshd_2223.log"
echo "SSH test servers on 2222 (SFTP) and 2223 (no SFTP)"

exec "$PY" -I "$HERE/ftp_test_server.py" "$DIR/root" "$DIR/cert.pem"
