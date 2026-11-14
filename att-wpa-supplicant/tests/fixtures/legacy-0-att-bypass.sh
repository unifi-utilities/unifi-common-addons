#!/bin/bash
# This script installs wpa_supplicant if it's not installed.

DATA_WPASUPPLICANT_DIR=/data/wpa_supplicant

if ! dpkg -l wpasupplicant 2>/dev/null | grep -q ii; then
    dpkg -i ${DATA_WPASUPPLICANT_DIR}/libpcsclite1*.deb
    dpkg -i ${DATA_WPASUPPLICANT_DIR}/libreadline8*.deb
    dpkg -i ${DATA_WPASUPPLICANT_DIR}/wpasupplicant_2.9*.deb
fi

WPASUPPLICANT_CONF_DIR=/etc/wpa_supplicant/conf
CA_PEM=${WPASUPPLICANT_CONF_DIR}/CA.pem
CLIENT_PEM=${WPASUPPLICANT_CONF_DIR}/Client.pem
PRIVATEKEY_PEM=${WPASUPPLICANT_CONF_DIR}/PrivateKey.pem
WPASUPPLICANT_CONF=${WPASUPPLICANT_CONF_DIR}/wpa_supplicant.conf

WPASUPPLICANT_SERVICE_DIR=/etc/systemd/system/wpa_supplicant.service.d
OVERRIDE_CONF=${WPASUPPLICANT_SERVICE_DIR}/override.conf

ONBOOT_DIR=/data/on_boot.d
ATT_BYPASS_SCRIPT=${ONBOOT_DIR}/0-att-bypass.sh

ATT_BYPASS_SERVICE=/etc/systemd/system/setup-att-bypass.service


if [ ! -d "$WPASUPPLICANT_CONF_DIR" ]; then
    mkdir -p ${WPASUPPLICANT_CONF_DIR}
fi

if [ ! -f "$CA_PEM" ]; then
    cp ${DATA_WPASUPPLICANT_DIR}/CA.pem ${WPASUPPLICANT_CONF_DIR}
fi

if [ ! -f "$CLIENT_PEM" ]; then
    cp ${DATA_WPASUPPLICANT_DIR}/Client.pem ${WPASUPPLICANT_CONF_DIR}
fi

if [ ! -f "$PRIVATEKEY_PEM" ]; then
    cp ${DATA_WPASUPPLICANT_DIR}/PrivateKey.pem ${WPASUPPLICANT_CONF_DIR}
fi

if [ ! -f "$WPASUPPLICANT_CONF" ]; then
    cp ${DATA_WPASUPPLICANT_DIR}/wpa_supplicant.conf ${WPASUPPLICANT_CONF_DIR}
fi



if [ ! -d "$WPASUPPLICANT_SERVICE_DIR" ]; then
    mkdir -p ${WPASUPPLICANT_SERVICE_DIR}
fi

if [ ! -f "$OVERRIDE_CONF" ]; then
    if /sbin/ethtool eth8 | grep -q "Link detected: yes"; then
        cp ${DATA_WPASUPPLICANT_DIR}/override_UDMPro_UDMProSE.conf ${DATA_WPASUPPLICANT_DIR}/override.conf
        cp ${DATA_WPASUPPLICANT_DIR}/override_UDMPro_UDMProSE.conf ${OVERRIDE_CONF}
    else
        cp ${DATA_WPASUPPLICANT_DIR}/override_UDM.conf ${DATA_WPASUPPLICANT_DIR}/override.conf
        cp ${DATA_WPASUPPLICANT_DIR}/override_UDM.conf ${OVERRIDE_CONF}
    fi
fi



systemctl daemon-reload
systemctl unmask wpa_supplicant.service
systemctl enable wpa_supplicant.service
systemctl restart wpa_supplicant.service
