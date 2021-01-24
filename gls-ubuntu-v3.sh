#!/bin/bash
# GLS - Ubuntu registration with satellite
# Author: Amir Weinstock (aweinsto@cisco.com)
#set -x

LOGFILE="/var/log/gls-ubuntu.log"
date +"%b-%d-%y" > $LOGFILE
APT_UPDATED=0
RELEASE=`/usr/bin/lsb_release --release --short`
RANDOMNAME=$(echo $(hostname -s)-$(head /dev/urandom | tr -dc a-z0-9 | head -c 5)  | tr '[:upper:]' '[:lower:]')
NTPSTATUS=$(systemctl show -p ActiveState ntp | cut -d = -f2)

dpkg --compare-versions "$RELEASE" "gt" "14.0"
if [ $? -eq "0" ]; then echo "Ubuntu version is correct..."
else
echo "Unsupported Ubuntu version."
exit
fi


if getent passwd laasadmin > /dev/null 2>&1; then
    
	PuppetUser="laasadmin"
else
	PuppetUser="satpuppet"    
	useradd  -G users,sudo  -m -d /home/satpuppet -p '$1$Zi0BkN2H$5DHrHj22of6lK07Pl9U0l0' satpuppet
fi



if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)"
  exit 1
fi

# Find the closest capsule server

while ! ping -c 1 -W 1 rhn-sat-allen-1.cisco.com; do
  echo "Waiting for network link..."
  sleep 1
done

Capsule[0]='rhn-cap1-ams.cisco.com'
Capsule[1]='rhn-cap2-ams.cisco.com'
Capsule[2]='rhn-cap3-ams.cisco.com'
Capsule[3]='rhn-cap4-ams.cisco.com'
Capsule[4]='rhn-cap-allen-1.cisco.com'
Capsule[5]='rhn-cap-allen-2.cisco.com'
Capsule[6]='rhn-cap-allen-3.cisco.com'
Capsule[7]='rhn-cap-allen-4.cisco.com'
Capsule[8]='rhn-cap1-rtp.cisco.com'
Capsule[9]='rhn-cap2-rtp.cisco.com'
Capsule[10]='rhn-cap3-rtp.cisco.com'
Capsule[11]='rhn-cap4-rtp.cisco.com'
Capsule[12]='rhn-cap5-rtp.cisco.com'

Num=200

for ((i=0;i<13;i++)); do
  TIME=$(ping -c1 ${Capsule[$i]} | grep time= |sed s,.*time=,, | cut -d " " -f1)
  COST=${TIME%.*}

  (( $COST < $Num )) && CapsuleServer=${Capsule[$i]} && Num=$COST
done

echo "Using capsule: $CapsuleServer" | tee -a $LOGFILE


# Install and configure NTP
if [ "$NTPSTATUS" == "inactive" ];then

# Unlock dpkg and fix broken packages
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock
dpkg --configure -a

# Installing required packages.
apt-get install ntp ntpdate ntpstat -y

# Disable the timesyncd service on the client and force time sync with Cisco's NTP servers.
systemctl stop ntp.service
timedatectl set-ntp off
wget -O /etc/ntp.conf http://$CapsuleServer/pub/gls/ntp.conf

# Starting the services 
systemctl start ntp.service
systemctl enable ntp.service

# Monitor NTP operations
ntpq -pn | tee -a $LOGFILE

fi

# Set up and configure the ClamAV
dpkg -s clamav &> /dev/null

if [ $? -eq 0 ]; then
  echo "ClamAV is installed...skipping." | tee -a $LOGFILE
else
  DEBIAN_FRONTEND=noninteractive apt-get update
  APT_UPDATED=1
  DEBIAN_FRONTEND=noninteractive apt-get install clamav clamav-daemon clamtk -y
fi


# Retrieve the freshclam config file
if [ -f /etc/clamav/freshclam.conf ];then
  mv /etc/clamav/freshclam.conf  /etc/clamav/freshclam.conf-bak
fi

wget -O /etc/clamav/freshclam.conf  http://$CapsuleServer/pub/distributions/ubuntu/latest/configfiles/freshclam-internal.conf --no-proxy
sed -i "s,XXX,$CapsuleServer,g" /etc/clamav/freshclam.conf

if [ -f /var/log/clamav/freshclam.log ];then
  rm -f  /var/log/clamav/freshclam.log
fi

# virus database update - Ignoring CLD warnings
freshclam --no-warnings | grep -vi cld | tee -a $LOGFILE

clamscan -V | tee -a $LOGFILE

if [ -f /usr/bin/systemctl ];then

systemctl enable clamav-daemon.service
systemctl start clamav-daemon.service
systemctl daemon-reload

else
service clamav-daemon start

fi



# Set up and configure the Puppet
dpkg -s puppet &> /dev/null

if [ $? -eq 0 ]; then
  echo "Puppet is installed...skipping." | tee -a $LOGFILE

# checking if puppet version is lower than 3.6.0
puppetVer=$(puppet --version)

dpkg --compare-versions "$puppetVer" "gt" "3.6.0"
if [ $? -eq "0" ]; then echo "puppet version is correct"
 else

 wget http://alln-lb-prod-1.cisco.com/pub/gls/puppetlabs-release-trusty.deb
 dpkg -i puppetlabs-release-trusty.deb
 apt-get update
 apt-get install puppet -y
fi

else
  if [ $APT_UPDATED -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install puppet -y
fi

# Clean previous puppet registration (if exists)
if [ -d /home/$PuppetUser/.puppet/ ];then
	rm -rf /home/$PuppetUser/.puppet/
fi

if [ ! -d /home/$PuppetUser/.puppet ]; then
  mkdir -p /home/$PuppetUser/.puppet/etc
  touch /home/$PuppetUser/.puppet/etc/puppet.conf
  # Ubuntu 18 puts the conf in ~/.puppet/etc, Ubuntu 14 puts it in ~/.puppet
  # Put it where 18 expects it and then symlink it to where 14 expects it.
  ln -s /home/$PuppetUser/.puppet/etc/puppet.conf /home/$PuppetUser/.puppet/puppet.conf
  chown -R $PuppetUser:$PuppetUser /home/$PuppetUser/.puppet
fi

# NOTE: these commands need to be run as $PuppetUser to keep from clobbering the
# LaaS puppet config.  Using su(1) as sudo(8) didn't work as expected.
su -lc "puppet config set server \"$CapsuleServer\" --section agent" $PuppetUser
su -lc "puppet config set ca_server \"$CapsuleServer\" --section agent" $PuppetUser
# The next line is for testing only.
su -lc "puppet config set certname $(echo ''$RANDOMNAME.cisco.com) --section agent" $PuppetUser
su -lc "puppet config --section agent set environment GLS" $PuppetUser
su -lc "puppet agent -t --waitforcert 60" $PuppetUser 2>/dev/null | tee -a $LOGFILE

# Add the service file and start up the service
if [ "$RELEASE" = "14.04" ]; then
  cd /etc/init

	if [ -f /etc/init/puppet-satellite.conf ];then
		rm -f /etc/init/puppet-satellite.conf 
	fi

  wget http://$CapsuleServer/pub/gls/puppet-satellite.conf
  initctl start puppet-satellite
else
  cd /lib/systemd/system

	if [ -f /lib/systemd/system/puppet-satellite.service ];then
		rm -f /lib/systemd/system/puppet-satellite.service
	fi

  wget http://$CapsuleServer/pub/gls/puppet-satellite.service
  systemctl enable puppet-satellite.service
  systemctl start puppet-satellite.service

fi

if [ ! -f /etc/cron.daily/cilp-trusted ];then
cd /etc/cron.daily/
wget http://$CapsuleServer/pub/gls/cilp-trusted  | tee -a $LOGFILE
chmod +x /etc/cron.daily/cilp-trusted
/etc/cron.daily/cilp-trusted  | tee -a $LOGFILE
fi


exit 0

