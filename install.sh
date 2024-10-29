#!/bin/bash

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
    echo "Bạn phải chạy script này với quyền root."
    exit 1
fi

# Cấu hình lại yum để sử dụng CentOS Vault
echo "Đang cấu hình lại yum để sử dụng CentOS Vault repositories..."
mkdir -p /etc/yum.repos.d/backup
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

cat <<EOF >/etc/yum.repos.d/CentOS-Vault.repo
[base]
name=CentOS-7 - Base
baseurl=http://vault.centos.org/7.9.2009/os/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-7 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-7 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF

yum clean all
yum makecache

# Cài đặt các gói cần thiết
echo "Đang cài đặt các gói cần thiết..."
yum -y install epel-release
yum -y groupinstall "Development Tools"
yum -y install net-tools tar zip curl

# Lấy tên giao diện mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# Khai báo các hàm cần thiết
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

install_3proxy() {
    echo "Đang cài đặt 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.cfg /usr/local/etc/3proxy/
    # Sao chép tệp unit systemd cho 3proxy
    cp scripts/systemd/3proxy.service /etc/systemd/system/3proxy.service
    systemctl daemon-reload
    systemctl enable 3proxy.service
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -n -a -p" $4 " -i" $3 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

upload_proxy() {
    local PASS=$(random)
    zip --password $PASS proxy.zip proxy.txt
    URL=$(curl -s --upload-file proxy.zip https://transfer.sh/proxy.zip)

    echo "Proxy đã sẵn sàng! Định dạng IP:PORT:LOGIN:PASS"
    echo "Tải tệp zip từ: ${URL}"
    echo "Mật khẩu: ${PASS}"
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "usr$(random)/pass$(random)/$IP4/$port"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -j ACCEPT"}' ${WORKDATA})
EOF
}

# Thiết lập thư mục làm việc
WORKDIR="/home/proxy-installer"
echo "Thư mục làm việc = ${WORKDIR}"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

# Đảm bảo tệp /etc/rc.local tồn tại và có quyền thực thi
if [ ! -f /etc/rc.local ]; then
    touch /etc/rc.local
    chmod +x /etc/rc.local
fi

# Lấy địa chỉ IP4
IP4=$(curl -4 -s icanhazip.com)
IP6=""

echo "IP nội bộ = ${IP4}"

# Yêu cầu người dùng nhập số lượng proxy cần tạo
echo "Bạn muốn tạo bao nhiêu proxy? Ví dụ 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT - 1))

# Gọi các hàm để tạo dữ liệu và cấu hình
gen_data >$WORKDATA
gen_iptables >$WORKDIR/boot_iptables.sh
chmod +x ${WORKDIR}/boot_*.sh

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

# Cập nhật /etc/rc.local để chạy các script khởi động
cat > /etc/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_iptables.sh
ulimit -n 10048
systemctl start 3proxy.service
EOF

chmod +x /etc/rc.local
systemctl enable rc-local
systemctl start rc-local

# Tạo tệp proxy cho người dùng
gen_proxy_file_for_user

# Tải lên tệp proxy và hiển thị thông tin
upload_proxy
