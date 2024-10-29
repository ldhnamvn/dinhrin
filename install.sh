#!/bin/bash

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
    echo "Bạn phải chạy script này với quyền root."
    exit 1
fi

# Cài đặt các gói cần thiết
echo "Đang cài đặt các gói cần thiết..."
yum clean all
yum makecache
yum -y install epel-release
yum -y install net-tools tar zip curl wget gcc make

# Lấy tên giao diện mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "Giao diện mạng của bạn là: $INTERFACE"

# Lấy địa chỉ IPv4
IP4=$(ip -4 addr show dev $INTERFACE | grep inet | awk '{print $2}' | cut -d'/' -f1)
echo "Địa chỉ IPv4 của bạn là: $IP4"

# Kiểm tra địa chỉ IP công cộng
if [[ $IP4 == 192.168.* || $IP4 == 10.* || $IP4 == 172.16.* || $IP4 == 172.31.* ]]; then
    echo "Cảnh báo: Địa chỉ IPv4 của bạn là địa chỉ IP nội bộ. Các proxy có thể không truy cập được từ bên ngoài."
fi

# Lấy địa chỉ IPv6
IP6=$(ip -6 addr show dev $INTERFACE | grep -v "fe80" | grep "scope global" | awk '{print $2}' | cut -d'/' -f1 | head -n1)
if [ -z "$IP6" ]; then
    echo "Không tìm thấy địa chỉ IPv6 trên giao diện $INTERFACE."
    USE_IPV6=false
else
    echo "Địa chỉ IPv6 của bạn là: $IP6"
    IP6_PREFIX=$(echo $IP6 | cut -d':' -f1-4)
    echo "Tiền tố IPv6 của bạn là: $IP6_PREFIX"
    USE_IPV6=true
fi

# Khai báo các hàm cần thiết
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

gen64() {
    if [ "$USE_IPV6" = true ]; then
        ip_suffix() {
            printf "%x:%x:%x:%x" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
        }
        echo "$IP6_PREFIX:$(ip_suffix)"
    else
        echo ""
    fi
}

install_3proxy() {
    echo "Đang cài đặt 3proxy..."
    URL="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget $URL -O 3proxy-0.9.4.tar.gz
    tar -xzf 3proxy-0.9.4.tar.gz
    cd 3proxy-0.9.4
    make
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp cfg/3proxy.cfg.sample /usr/local/etc/3proxy/3proxy.cfg
    # Tạo tệp unit systemd cho 3proxy
    cat <<EOF >/etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 3proxy.service
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF >/usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid $(id -g nobody)
setuid $(id -u nobody)
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})
EOF

    while IFS="/" read -r username password ip4 port ip6; do
        echo "auth strong" >>/usr/local/etc/3proxy/3proxy.cfg
        echo "allow $username" >>/usr/local/etc/3proxy/3proxy.cfg
        if [ "$USE_IPV6" = true ]; then
            echo "proxy -6 -n -a -p$port -i$ip4 -e$ip6" >>/usr/local/etc/3proxy/3proxy.cfg
        else
            echo "proxy -n -a -p$port -i$ip4" >>/usr/local/etc/3proxy/3proxy.cfg
        fi
        echo "flush" >>/usr/local/etc/3proxy/3proxy.cfg
    done < ${WORKDATA}
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
        if [ "$USE_IPV6" = true ]; then
            echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64)"
        else
            echo "usr$(random)/pass$(random)/$IP4/$port"
        fi
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
    if [ "$USE_IPV6" = true ]; then
        cat <<EOF
$(awk -F "/" -v interface="$INTERFACE" '{print "ip -6 addr add " $5 "/64 dev " interface}' ${WORKDATA})
EOF
    else
        echo "# Không cần cấu hình IPv6"
    fi
}

# Thiết lập thư mục làm việc
WORKDIR="/home/proxy-installer"
echo "Thư mục làm việc = ${WORKDIR}"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

# Đảm bảo tệp /etc/rc.d/rc.local tồn tại và có quyền thực thi
if [ ! -f /etc/rc.d/rc.local ]; then
    touch /etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
fi

# Yêu cầu người dùng nhập số lượng proxy cần tạo
echo "Bạn muốn tạo bao nhiêu proxy? Ví dụ 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT - 1))

# Gọi các hàm để tạo dữ liệu và cấu hình
gen_data >$WORKDATA
gen_iptables >$WORKDIR/boot_iptables.sh
chmod +x ${WORKDIR}/boot_*.sh

if [ "$USE_IPV6" = true ]; then
    gen_ifconfig >$WORKDIR/boot_ifconfig.sh
    chmod +x $WORKDIR/boot_ifconfig.sh
fi

install_3proxy

gen_3proxy

# Cập nhật /etc/rc.d/rc.local để chạy các script khởi động
cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_iptables.sh
$(if [ "$USE_IPV6" = true ]; then echo "bash ${WORKDIR}/boot_ifconfig.sh"; fi)
ulimit -n 10048
systemctl start 3proxy.service
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local
systemctl start rc-local

# Tạo tệp proxy cho người dùng
gen_proxy_file_for_user

# Tải lên tệp proxy và hiển thị thông tin
upload_proxy
