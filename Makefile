all:
	sudo umount /mnt2 || exit 0
	./fuse_dbi.pl /mnt2
	sudo umount /mnt2

test:
	psql -q -t -A -c "select template from template where oid=3035699" webgui > foo
