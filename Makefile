all:
	sudo umount /mnt2
	./fuse_dbi.pl /mnt2
	sudo umount /mnt2
