#!/usr/bin/env tcsh

set verbose

#
# Variables
#

set SWAP_SIZE=16G
set BOOT_SIZE=2G
set HOSTNAME=junkiexl1.localdomain
set DESTDIR=/mnt
set PASSPHRASE=lenovoX61T

#
# Prepare environment
#

mkdir /tmp/etc
mdmfs -s32m -S md /tmp/etc
mount -t unionfs /tmp/etc /etc
echo password | pw usermod root -h 0
cat >> /etc/resolv.conf <<__EOF__
8.8.8.8
8.8.4.4
__EOF__
route add default 64.79.70.65
ifconfig igb0 inet 64.79.70.66 netmask 255.255.255.248
echo PermitRootLogin=yes >> /etc/ssh/sshd_config
service sshd onestart

#
# Partitions
#

kldload zfs aesni geom_eli

cd /dev
for I (mfid0 mfid1 mfid2)
 set NUMBER=$( echo ${I} | tr -c -d '0-9' )
 gpart destroy -F ${I}
 gpart create -s GPT ${I}
 gpart add -b 40 -s 256 -t freebsd-boot ${I}
 gpart add -b 2048 -s $BOOT_SIZE -t freebsd-zfs -l boot${NUMBER} ${I}
 gpart add -t freebsd-zfs -l root${NUMBER} ${I}
 gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${I}
end

#
# /
#

echo $PASSPHRASE | geli init -b -e AES-CBC -l 256 -s 4096 -B none -J - /dev/gpt/root0
echo $PASSPHRASE | geli init -b -e AES-CBC -l 256 -s 4096 -B none -J - /dev/gpt/root1
echo $PASSPHRASE | geli init -b -e AES-CBC -l 256 -s 4096 -B none -J - /dev/gpt/root2
echo $PASSPHRASE | geli attach -j - /dev/gpt/root0
echo $PASSPHRASE | geli attach -j - /dev/gpt/root1
echo $PASSPHRASE | geli attach -j - /dev/gpt/root2
zpool create -o altroot=$DESTDIR -o cachefile=/tmp/zpool.cache -m none zroot mirror /dev/gpt/root0.eli /dev/gpt/root1.eli /dev/gpt/root2.eli
zfs set checksum=fletcher4 zroot
zfs set atime=off zroot
zfs set mountpoint=none zroot
zfs create zroot/ROOT
zfs create -o mountpoint=/ zroot/ROOT/default
zpool set bootfs="zroot/ROOT/default" zroot

#
# /boot
#

gnop create -S 4096 /dev/gpt/boot0
gnop create -S 4096 /dev/gpt/boot1
gnop create -S 4096 /dev/gpt/boot2
# zero out the start of boot partition, just in case
dd if=/dev/zero of=/dev/gpt/boot0.nop bs=1M
dd if=/dev/zero of=/dev/gpt/boot1.nop bs=1M
dd if=/dev/zero of=/dev/gpt/boot2.nop bs=1M
zpool create -o altroot=$DESTDIR -o cachefile=/tmp/zpool.cache -m none zboot mirror /dev/gpt/boot0.nop /dev/gpt/boot1.nop /dev/gpt/boot2nop
zpool export zboot
gnop destroy /dev/gpt/boot0.nop
gnop destroy /dev/gpt/boot1.nop
gnop destroy /dev/gpt/boot2.nop
zpool import -o altroot=$DESTDIR -o cachefile=/tmp/zpool.cache zboot
zfs set checksum=fletcher4 zboot
zfs set atime=off zboot
zfs set mountpoint=none zboot
zfs create zboot/ROOT
zfs create -o mountpoint=/bootfs zboot/ROOT/default
zpool set bootfs="zboot/ROOT/default" zboot

#
# /usr
#

zfs create -o mountpoint=/usr zroot/ROOT/default/usr
zfs create zroot/ROOT/default/usr/local

zfs create -o compression=lzjb -o exec=off -o setuid=off zroot/ROOT/default/usr/src
zfs create zroot/ROOT/default/usr/obj
zfs create -o compression=lzjb -o setuid=off zroot/ROOT/default/usr/ports
zfs create -o compression=off  -o exec=off -o setuid=off zroot/ROOT/default/usr/ports/distfiles
zfs create -o compression=off  -o exec=off -o setuid=off zroot/ROOT/default/usr/ports/packages


#
# /var
#

zfs create -o mountpoint=/var zroot/ROOT/default/var
zfs create -o compression=lzjb -o exec=off -o setuid=off zroot/ROOT/default/var/crash
zfs create -o exec=off -o setuid=off zroot/ROOT/default/var/db
zfs create -o compression=lzjb -o exec=on -o setuid=off zroot/ROOT/default/var/db/pkg
zfs create -o compression=lzjb -o exec=off -o setuid=off zroot/ROOT/default/var/log
zfs create -o compression=gzip -o exec=off -o setuid=off zroot/ROOT/default/var/mail
zfs create -o exec=off -o setuid=off zroot/ROOT/default/var/run
zfs create -o exec=off -o setuid=off zroot/ROOT/default/var/empty

#
# /var/tmp, /tmp
#

zfs create -o compression=lzjb -o exec=on -o setuid=off zroot/ROOT/default/var/tmp
chmod 1777 $DESTDIR/var/tmp
zfs create -o mountpoint=/tmp -o compression=on -o exec=on -o setuid=off zroot/tmp
chmod 1777 $DESTDIR/tmp

#
# /home
#

zfs create -o mountpoint=/home zroot/home

#
# FreeBSD sets
#

foreach file (/usr/freebsd-dist/*.txz)
 tar --unlink -xpJf ${file} -C $DESTDIR
end
#foreach file (base.txz kernel.txz lib32.txz)
# tar --unlink -xpJf /usr/freebsd-dist/${file} -C $DESTDIR
#end

#
# Finishing zfs config
# /var/empty and Swap
#

zfs set readonly=on zroot/ROOT/default/var/empty
zfs create -V $SWAP_SIZE -o org.freebsd:swap=on -o checksum=off -o sync=disabled -o primarycache=none -o secondarycache=none zroot/swap

#
# /boot on zboot
#

mv $DESTDIR/boot $DESTDIR/bootfs/boot
ln -shf bootfs/boot $DESTDIR/boot
chflags -h schg $DESTDIR/boot
cp /tmp/zpool.cache $DESTDIR/boot/zfs/zpool.cache

#
# FreeBSD Boot Loader
#

cat >> $DESTDIR/boot/loader.conf <<__EOF__
aesni_load="YES"
geom_eli_load="YES"
kern.geom.eli.visible_passphrase="2"
zfs_load="YES"
vfs.root.mountfrom="zfs:zroot/ROOT/default"
__EOF__

#
# Settings
#

echo hostname=\"$HOSTNAME\" >> $DESTDIR/etc/rc.conf
cat >> $DESTDIR/etc/rc.conf <<__EOF__
ifconfig_igb0="inet 64.79.70.66 netmask 255.255.255.248"
defaultrouter="64.79.70.65"
zfs_enable="YES"
sshd_enable="YES"
__EOF__
echo $PASSPHRASE | pw -V $DESTDIR/etc usermod root -h 0
touch $DESTDIR/etc/fstab
# we'll mount /bootfs in fstab, since it is a legacy-mounted FS in zfs
echo '# Device  		Mountpoint	FStype	Options		Dump	Pass#' >> $DESTDIR/etc/fstab
echo 'zboot/ROOT/default	/bootfs		zfs	rw,noatime	0	0' >> $DESTDIR/etc/fstab
echo 'WRKDIRPREFIX=/usr/obj' >> $DESTDIR/etc/make.conf
tzsetup -C $DESTDIR UTC
cd $DESTDIR/etc/mail
setenv SENDMAIL_ALIASES $DESTDIR/etc/mail/aliases
make aliases
freebsd-update -b $DESTDIR fetch
freebsd-update -b $DESTDIR install
#fetch -o $DESTDIR/usr/sbin/beadm https://raw.github.com/vermaden/beadm/master/beadm
#chmod ug+x $DESTDIR/usr/sbin/beadm
fetch -o $DESTDIR/usr/sbin/beadm https://bitbucket.org/aasoft/beadm/raw/mydev/beadm
chmod ug+x $DESTDIR/usr/sbin/beadm

cd /
zfs umount -a
zfs set mountpoint=legacy zboot/ROOT/default
zfs set mountpoint=legacy zroot/ROOT/default
zfs snapshot -r zboot/default@install
# snapshot -r zroot/ROOT/default@install

