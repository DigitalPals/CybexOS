# Defaults for interactive installation only: no storage or account answers.
# Fedora 44 executes scripts through the Runtime DBus module, which reads
# this file before the legacy post-scripts loader updates its local ksdata.
%include /usr/share/anaconda/post-scripts/90-cybexos.ks
