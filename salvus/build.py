#!/usr/bin/env python

"""
Building the main components of cloud.sagemath.com from source, ensuring that all
important (usually security-related) options are compiled in.

The components are:

    * python -- build managements and some packages
    * node.js -- dynamic async; most things
    * nginx -- static web server
    * haproxy -- proxy and load balancer
    * stunnel -- ssl termination
    * tinc -- p2p vpn
    * cassandra -- distributed database
    * bup -- git-ish backup
    * sage -- we do *not* build or include Sage; it must be available system-wide or for
      user in order for worksheets to work (everything but worksheets should work without Sage).

Supported Platform: Ubuntu 12.04

Before building, do:

# For a full machine with shared users:

    Change this line in /etc/login.defs:  "UMASK           077"

  Don't bother for LXC.

# LIBC version:

  On Debian, add this line to /etc/apt/sources.list

      deb     http://http.debian.net/debian jessie main

  Then do "apt-get update", then "apt-cache policy libc-dev6" to find the newest version.
  Then do
      apt-get install libc6-dev=2.17-97
  and finally comment out the above line and do "apt-get update" again, in order to avoid breaking "apt-get upgrade".


# ATLAS:

         apt-get install libatlas3gf-base liblapack-dev
         cd /usr/lib/
         ln -s libatlas.so.3gf libatlas.so
         ln -s libcblas.so.3gf libcblas.so
         ln -s libf77blas.so.3gf libf77blas.so

   This line is in the .sagemathcloud env, so building sage is fast for users (though not as performant)

         export SAGE_ATLAS_LIB="/usr/lib/"


# Install critical packages:

         apt-get install vim git wget iperf dpkg-dev make m4 g++ gfortran liblzo2-dev libssl-dev libreadline-dev  libsqlite3-dev libncurses5-dev git zlib1g-dev openjdk-7-jdk libbz2-dev libfuse-dev pkg-config libattr1-dev libacl1-dev par2 ntp pandoc ssh python-lxml  calibre  ipython python-pyxattr python-pylibacl software-properties-common  libevent-dev xfsprogs lsof


# Install ZFS (see http://zfsonlinux.org/generic-deb.html)

    apt-get install build-essential gawk alien fakeroot linux-headers-$(uname -r) zlib1g-dev uuid-dev libblkid-dev libselinux-dev parted lsscsi wget

    wget http://archive.zfsonlinux.org/downloads/zfsonlinux/spl/spl-0.6.2.tar.gz
    wget http://archive.zfsonlinux.org/downloads/zfsonlinux/zfs/zfs-0.6.2.tar.gz

    tar -xzf spl-0.6.2.tar.gz
    tar -xzf zfs-0.6.2.tar.gz

    # **IMPORTANT**!  See https://github.com/zfsonlinux/zfs/issues/845
    # comment out line 98 in zfs-0.6.2/lib/libshare/libshare.c so have this:
    #
    #      /* update_zfs_shares(impl_handle, NULL); */
    #

    cd spl-0.6.2
    ./configure
    make deb-utils deb-kmod
    dpkg -i kmod-spl-devel_0.6.2-1_amd64.deb kmod-spl-devel-3*.deb

    cd ../zfs-0.6.2
    ./configure
    make deb-utils deb-kmod
    cd ..

    dpkg -i */*.deb

# LZ4 -- compression

    # Ubuntu
    sudo add-apt-repository ppa:gezakovacs/lz4; sudo apt-get update; sudo apt-get install liblz4-tool

    # Debian
    cd /tmp/; wget https://dl.dropboxusercontent.com/u/59565338/LZ4/lz4-r109.tar.gz; tar xvf lz4-r109.tar.gz; cd lz4-r109; make install; rm -rf /tmp/lz4-r109


# For VM hardware hosts only (?):  chmod a+rw /dev/fuse


# Add this to /etc/ssh/sshd_config

MaxStartups 128


# Additional packages (mainly for users, not building).

On Ubuntu 13.10

   sudo apt-get install emacs vim texlive texlive-* gv imagemagick octave mercurial flex bison unzip libzmq-dev uuid-dev scilab axiom yacas octave-symbolic quota quotatool dot2tex python-numpy python-scipy python-pandas python-tables libglpk-dev python-h5py zsh python3 python3-zmq python3-setuptools cython htop ccache python-virtualenv clang libgeos-dev libgeos++-dev sloccount racket libxml2-dev libxslt-dev irssi libevent-dev tmux sysstat sbcl gawk noweb libgmp3-dev ghc  ghc-doc ghc-haddock ghc-mod ghc-prof haskell-mode haskell-doc subversion cvs bzr rcs subversion-tools git-svn markdown lua5.2 lua5.2-*  encfs auctex vim-latexsuite yatex spell cmake libpango1.0-dev xorg-dev gdb valgrind doxygen haskell-platform haskell-platform-doc haskell-platform-prof  mono-devel mono-tools-devel ocaml ocaml-doc tuareg-mode ocaml-mode libgdbm-dev mlton sshfs sparkleshare fig2ps epstool libav-tools python-software-properties software-properties-common h5utils libhdf5-dev libhdf5-doc libnetcdf-dev netcdf-doc netcdf-bin tig libtool iotop asciidoc autoconf bsdtar attr tcl-dev tk-dev golang-go libicu-dev libicu-devlibicu-dev libicu-dev libicu-dev iceweasel xvfb


On Debian 7 (Google)

apt-get install emacs vim texlive texlive-* gv imagemagick octave mercurial flex bison unzip libzmq-dev uuid-dev scilab axiom yacas octave-symbolic quota quotatool dot2tex python-numpy python-scipy python-pandas python-tables libglpk-dev python-h5py zsh python3 python3-zmq python3-setuptools cython htop ccache python-virtualenv clang libgeos-dev libgeos++-dev sloccount racket libxml2-dev libxslt-dev irssi libevent-dev tmux sysstat sbcl gawk noweb libgmp3-dev ghc  ghc-doc ghc-haddock ghc-mod ghc-prof haskell-mode haskell-doc subversion cvs bzr rcs subversion-tools git-svn markdown lua5.2 lua5.2-*  encfs auctex vim-latexsuite yatex cmake libpango1.0-dev xorg-dev gdb valgrind doxygen haskell-platform haskell-platform-doc haskell-platform-prof  mono-devel mono-tools-devel ocaml  tuareg-mode ocaml-mode libgdbm-dev mlton sshfs sparkleshare fig2ps epstool libav-tools python-software-properties software-properties-common h5utils libhdf5-dev libhdf5-doc libnetcdf-dev netcdf-doc netcdf-bin tig libtool iotop asciidoc autoconf spell golang-go libicu-dev libicu-devlibicu-dev libicu-dev libicu-dev iceweasel xvfb


# Aldor - in 13.10, have to modify /etc/apt/sources.list.d/pippijn-ppa-*.list and replace version with "precise"
   sudo add-apt-repository ppa:pippijn/ppa
   sudo apt-get update; sudo apt-get install aldor open-axiom*

NOTE: With ubuntu 12.04 I do this:
          apt-add-repository ppa:texlive-backports/ppa
          apt-get update; apt-get dist-upgrade

# upgrade to octave 3.6 -- Only on ubuntu 12.04!
          apt-add-repository ppa:dr-graef/octave-3.6.precise
          apt-get update; apt-get install octave;  # or is it apt-get dist-upgrade  ?

          cd /usr/share/fonts/truetype; ln -s liberation ttf-liberation   # needed by octave for plotting.


# Tmux -- Ensure tmux is at least 1.8 and if not:

tmux -V

       wget http://downloads.sourceforge.net/tmux/tmux-1.8.tar.gz && tar xvf tmux-1.8.tar.gz && cd tmux-1.8/ &&  ./configure && make -j40 && sudo make install &&  cd .. && rm -rf tmux-1.8*


# Dropbox --
  so it's possible to setup dropbox to run in projects... at some point (users could easily do this anyways, but making it systemwide is best).

      Get it here: https://www.dropbox.com/install?os=lnx


# SAGE SCRIPTS:
  Do from within Sage (as root):

      install_scripts('/usr/local/bin/')

# POLYMAKE system-wide:

  # From http://www.polymake.org/doku.php/howto/install

     sudo apt-get install ant default-jdk g++ libboost-dev libgmp-dev libgmpxx4ldbl libmpfr-dev libperl-dev libsvn-perl libterm-readline-gnu-perl libxml-libxml-perl libxml-libxslt-perl libxml-perl libxml-writer-perl libxml2-dev w3c-dtd-xhtml xsltproc

  # Then... get latest from http://www.polymake.org/doku.php/download/start and build:
      sudo su
      cd /tmp/; wget http://www.polymake.org/lib/exe/fetch.php/download/polymake-2.12-rc3.tar.bz2; tar xvf polymake-2.12-rc3.tar.bz2; cd polymake-2.12; ./configure; make -j4; make install
      rm -rf /tmp/polymake*


# MACAULAY2:

   Install Macaulay2 system-wide from here: http://www.math.uiuc.edu/Macaulay2/Downloads/

## Ubuntu:

    sudo su
    # apt-get install libntl-5.4.2 libpari-gmp3  # ubuntu 12.04
    apt-get install libntl-dev libntl0  libpari-gmp3 # ubuntu 13.10
    cd /tmp/; wget http://www.math.uiuc.edu/Macaulay2/Downloads/Common/Macaulay2-1.6-common.deb; wget http://www.math.uiuc.edu/Macaulay2/Downloads/GNU-Linux/Ubuntu/Macaulay2-1.6-amd64-Linux-Ubuntu-12.04.deb; sudo dpkg -i Macaulay2-1.6-common.deb Macaulay2-1.6-amd64-Linux-Ubuntu-12.04.deb; rm *.deb

## Debian

    sudo su
    apt-get install libntl-dev libntl0  libpari-gmp3
    cd /tmp/; rm Macaulay2*.deb; wget http://www.math.uiuc.edu/Macaulay2/Downloads/GNU-Linux/Debian/Macaulay2-1.6-amd64-Linux-Debian-7.0.deb; wget http://www.math.uiuc.edu/Macaulay2/Downloads/Common/Macaulay2-1.6-common.deb;  sudo dpkg -i Macaulay2*.deb; rm Macaulay2*.deb

# Install Julia

   sudo su
   umask 022; cd /usr/local/; git clone git://github.com/JuliaLang/julia.git; cd julia; make -j4 install;  cd /usr/local/bin; ln -s /usr/local/julia/julia .

# FEnICS -- automated solution of differential equations by finite element methods

    add-apt-repository ppa:fenics-packages/fenics
    apt-get update; apt-get install fenics


# Snappy

    umask 022; sage -i http://snappy.computop.org/get/snappy-2.0.3.spkg


# Build Sage (as usual)

    umask 022   # always do this so that the resulting build is usable without painful permission hacking.
                # the hack would be:
                #   chmod a+r -R .;    find . -perm /u+x -execdir chmod a+x {} \;

    #export SAGE_ATLAS_LIB=/usr/lib/   #<--- too slow!
    export MAKE="make -j20"
    make

# Make the new Sage able to import stuff installed in the system-wide python, e.g., "import dolfin" (some complicated FEM library)

    cd $SAGE_ROOT/local/lib/python
    echo "import sys; sys.path.append('/usr/lib/python2.7/dist-packages/'); sys.path.append('/usr/lib/pymodules/python2.7')" >> sitecustomize.py
    chmod a+r sitecustomize.py

# Workaround bugs in Sage

   - http://trac.sagemath.org/ticket/15178 -- bug in pexpect, which breaks ipython !ls.
     (just put f=filename in function which in /usr/local/sage/current/local/lib/python2.7/site-packages/pexpect.py)

# Non-sage Python packages into Sage

    sage -sh
    wget https://raw.github.com/pypa/pip/master/contrib/get-pip.py; python get-pip.py

    sudo su
    cd /tmp; wget http://download.osgeo.org/proj/proj-4.8.0.tar.gz; tar xvf proj-4.8.0.tar.gz; cd proj-4.8.0; ./configure --prefix=/usr; make install

# pip install each of these in a row: unfortunately "pip install <list of packages>" doesn't work at all.
# Execute this inside of sage:

    os.environ['PROJ_DIR']='/usr/'; os.environ['NETCDF4_DIR']='/usr'; os.environ['HDF5_DIR']='/usr'
    [(s, os.system("pip install %s"%s)) for s in 'tornado virtualenv pandas statsmodels numexpr tables scikit_learn theano scikits-image  Shapely SimPy xlrd xlwt pyproj bitarray h5py netcdf4 patsy lxml munkres oct2py psutil plotly mahotas'.split()]

#('pandas', 'statsmodels', 'lxml')

(Mike Hansen remarks: You can just have a text file with a list of the package names (with or without versions) in say extra_packages.txt and do "pip install -r extra_packages.txt")

Also do this into sage (where the version may change -- check -- https://pypi.python.org/pypi/scimath); I don't understand why pip doesn't work, but it doesn't:

    ./sage -sh
     wget http://www.enthought.com/repo/ets/scimath-4.1.2.tar.gz; tar xvf scimath-4.1.2.tar.gz; cd scimath-4.1.2; python setup.py install; cd ..; rm -rf scimath-4.1.2*

# Clawpack: requires a special flag

    # system-wide
    sudo su; umask 022; pip install clawpack

    # in sage
    sage -sh; umask 022
    export LDFLAGS=-shared; pip install clawpack

# We have to upgrade rpy2, since the one in sage is so old, and it breaks ipython's r interface.

    pip install --upgrade rpy2

# Neuron -- requested by Jose Guzman

   umask 022
   cd /tmp; hg clone http://www.neuron.yale.edu/hg/neuron/iv; hg clone http://www.neuron.yale.edu/hg/neuron/nrn
   sage -sh
   cd /tmp/iv; ./build.sh; ./configure --prefix=/usr/local/; make -j16; sudo make install
   # the make install below ends in an error, but it seems to work for people who care.
   cd /tmp/nrn; ./build.sh; ./configure --prefix=/usr/local/ --with-iv=/usr/local/ --with-nrnpython; make -j16; sudo make install; cd src/nrnpython/; python setup.py install
   rm -rf /tmp/iv /tmp/nrn

Test with "import neuron".

# basemap -- won't install through pip/easy_install, so we do this:

    sage -sh
    wget http://downloads.sourceforge.net/project/matplotlib/matplotlib-toolkits/basemap-1.0.7/basemap-1.0.7.tar.gz; tar xf basemap-1.0.7.tar.gz; cd basemap-1.0.7; python setup.py install; cd ..; rm -rf basemap-1.0.7*

## TEST:   echo "from mpl_toolkits.basemap import Basemap" | python

# System-wide Python packages not through apt:

   umask 022; /usr/bin/pip install -U scikit-learn theano


# Also, edit the banner:

  local/bin/sage-banner

        +--------------------------------------------------------------------+
        | Sage Version 5.10.beta5, Release Date: 2013-05-26                  |
        | Enhanced for the SageMathCloud                                     |
        | Type "help()" for help.                                            |
        +--------------------------------------------------------------------+

# OPTIONAL SAGE PACKAGES

    Add this back to src/bin/sage-env:

        # this is to be compatible with optional packages that haven't
        # been updated to not use SAGE_DATA
        export SAGE_DATA="$SAGE_SHARE"

    ln -s local/share data

    ./sage -i biopython-1.61  chomp database_cremona_ellcurve database_odlyzko_zeta database_pari biopython brian cbc cluster_seed coxeter3 cryptominisat cunningham_tables database_gap database_jones_numfield database_kohel database_sloane_oeis database_symbolic_data dot2tex gap_packages gnuplotpy guppy kash3  lie lrs nauty normaliz nose nzmath p_group_cohomology phc pybtex pycryptoplus pyx pyzmq qhull  topcom zeromq stein-watkins-ecdb

# temporary workaround:

    ./sage -i http://sage.math.washington.edu/home/SimonKing/Cohomology/p_group_cohomology-2.1.4.p1.spkg


# R Packages into Sage's R:

    umask 022 && sage -R
    install.packages(c("ggplot2", "stringr", "plyr", "reshape2", "zoo", "car", "mvtnorm", "e1071", "Rcpp", "lattice",  "KernSmooth", "Matrix", "cluster", "codetools", "mgcv", "rpart", "survival", "fields", "circular", "glmnet"), repos='http://cran.cs.wwu.edu/')

r packages could be automated like so (?)

                0 jan@snapperkob:~/src/r-install-packages-0.1ubuntu5$cat r-install-packages.R
                #! /usr/bin/Rscript --vanilla
                options(repos="http://cran.ru.ac.za/")
                res <- try(install.packages(c("deSolve", "fracdiff", "plyr", "reshape2", "ggplot2", "PBSddesolve"), dependencies=TRUE))

                if(inherits(res, "try-error")) q(status=1) else q()
                0 jan@snapperkob:~/src/r-install-packages-0.1ubuntu5$

# R 3.x system-wide:

  Add this to /etc/apt/sources.list:

     deb http://cran.cnr.Berkeley.edu/bin/linux/ubuntu precise/        # ubuntu

     deb http://cran.cnr.Berkeley.edu/bin/linux/debian wheezy-cran3/   # debian

  Then

     apt-get update; apt-get upgrade; apt-get install r-recommended

     umask 022 && /usr/bin/R
     install.packages(c("ggplot2", "stringr", "plyr", "reshape2", "zoo", "car", "mvtnorm", "e1071", "Rcpp", "lattice",  "KernSmooth", "Matrix", "cluster", "codetools", "mgcv", "rpart", "survival", "fields", "circular", "glmnet"), repos='http://cran.cs.wwu.edu/')


# 4ti2 into sage: until the optional spkg gets fixed:

    ./sage -sh
    cd /tmp; wget http://www.4ti2.de/version_1.6/4ti2-1.6.tar.gz && tar xf 4ti2-1.6.tar.gz && cd 4ti2-1.6 ; ./configure --prefix=/usr/local/sage/current/local/; time make -j16
    make install      # this *must* be a separate step!!
    rm -rf /tmp/4ti2*


# Update to ipython 1.1.0

    sage -sh
    pip install --upgrade ipython
    cd $SAGE_ROOT/devel/sage; wget http://wstein.org/home/wstein/tmp/trac-14713.patch; hg import trac-14713.patch
    cd $SAGE_ROOT/; ./sage -br

# Fix permissions, just in case.

    cd /usr/local/sage/current; chmod -R a+r *; find . -perm /u+x -execdir chmod a+x {} \;


# Delete cached packages

   #cd SAGE_ROOT
   rm -rf upstream; local/var/tmp/sage/build/

# Run sage one last time

  ./sage

# Copy over the newest SageTex, so it actually works (only do this with the default sage):

    sudo su
    umask 022
    cp -rv /usr/local/sage/current/local/share/texmf/tex/generic/sagetex /usr/share/texmf/tex/latex/; texhash

# Setup /usr/local/bin/skel

   rsync -axvHL ~/salvus/salvus/local_hub_template/ ~/.sagemathcloud/
   cd ~/.sagemathcloud
   . sagemathcloud-env
   ./build

   cd /usr/local/bin/
   sudo ln -s /home/salvus/salvus/salvus/scripts/skel/ .

   cd ~/salvus/salvus/scripts/skel/
   mv ~/.sagemathcloud .


# Salvus (needs more!)

   cd /home/salvus/salvus/salvus/
   mkdir local_hub_template/node_modules
   cp scripts/skel/.sagemathcloud/node_modules/*.js local_hub_template/node_modules/
   ./make_coffee --all

# GCE problems:
   julia fails to build: as above
   system-wide theano fails to install: /usr/bin/pip install -U theano  # but fine in sage.

"""

TINC_VERSION='1.0.23'       # options here -- http://tinc-vpn.org/packages/
CASSANDRA_VERSION='1.2.9'   # options here -- http://downloads.datastax.com/community/
NODE_VERSION='0.10.21'      # options here -- http://nodejs.org/dist/   -- 0.[even].* is STABLE version.
SETUPTOOLS_VERSION='2.0.2'  # options here (bottom!) -- https://pypi.python.org/pypi/setuptools

import logging, os, shutil, subprocess, sys, time

# Enable logging
logging.basicConfig()
log = logging.getLogger('')
log.setLevel(logging.DEBUG)   # WARNING, INFO

OS     = os.uname()[0]
PWD    = os.path.abspath('.')
DATA   = os.path.abspath('data')
SRC    = os.path.abspath('src')
PATCHES= os.path.join(SRC, 'patches')
BUILD  = os.path.abspath(os.path.join(DATA, 'build'))
PREFIX = os.path.abspath(os.path.join(DATA, 'local'))
os.environ['PREFIX'] = PREFIX

if 'MAKE' in os.environ:
    del os.environ['MAKE']

# WARNING--as of Sept 1, 2013, start-stop-daemon's install is broken, even though no versions (and no dep versions) have changed,
# due to some packages cheating npm.  So I'm typically just copying over node_modules/start-stop-daemon from previous installs.

NODE_MODULES = [
    'commander', 'start-stop-daemon', 'winston', 'sockjs', 'node-cassandra-cql',
    'sockjs-client-ws', 'coffee-script', 'node-uuid', 'browserify@1.16.4', 'uglify-js2',
    'passport', 'passport-github', 'express', 'nodeunit', 'validator', 'async',
    'password-hash',
    'emailjs@0.3.4',   # version hold back because of https://github.com/eleith/emailjs/commits/master
    'cookies', 'htmlparser', 'mime', 'pty.js', 'posix',
    'mkdirp', 'walk', 'temp', 'googlediff', 'formidable@latest',
    'moment', 'underscore', 'read', 'hashring', 'rimraf'
    ]

PYTHON_PACKAGES = [
    'ipython','readline', # a usable command line  (ipython uses readline)
    'python-daemon',      # daemonization of python modules
    'paramiko',           # ssh2 implementation in python
    'cql',                # interface to Cassandra
    'fuse-python',        # used by bup: Python bindings to "filesystem in user space"
    'pyxattr',            # used by bup
    'pylibacl',           # used by bup
    'pyinotify'
    ]

if not os.path.exists(BUILD):
    os.makedirs(BUILD)

os.environ['PATH'] = os.path.join(PREFIX, 'bin') + ':' + os.environ['PATH']
os.environ['LD_LIBRARY_PATH'] = os.path.join(PREFIX, 'lib') + ':' + os.environ.get('LD_LIBRARY_PATH','')

# number of cpus
try:
    NCPU = os.sysconf("SC_NPROCESSORS_ONLN")
except:
    NCPU = int(subprocess.Popen("sysctl -n hw.ncpu", shell=True, stdin=subprocess.PIPE,
                 stdout = subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True).stdout.read())

log.info("detected %s cpus", NCPU)


def cmd(s, path):
    s = 'cd "%s" && '%path + s
    log.info("cmd: %s", s)
    if os.system(s):
        raise RuntimeError('command failed: "%s"'%s)

def download(url):
    # download target of given url to SRC directory
    cmd("wget '%s'"%url, SRC)

def extract_package(basename):
    # find tar ball in SRC directory, extract it in build directory, and return resulting path
    for filename in os.listdir(SRC):
        if filename.startswith(basename):
            i = filename.rfind('.tar.')
            path = os.path.join(BUILD, filename[:i])
            if os.path.exists(path):
                shutil.rmtree(path)
            cmd('tar xf "%s"'%os.path.abspath(os.path.join(SRC, filename)), BUILD)
            return path

def build_tinc():
    log.info('building tinc'); start = time.time()
    try:
        target = 'tinc-%s.tar.gz'%TINC_VERSION
        if not os.path.exists(os.path.join(SRC, target)):
            cmd("rm -f tinc-*.tar.*", SRC)
            download("http://tinc-vpn.org/packages/tinc-%s.tar.gz"%TINC_VERSION)
        path = extract_package('tinc')
        cmd('./configure --prefix="%s"'%PREFIX, path)
        cmd('make -j %s'%NCPU, path)
        cmd('make install', path)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_python():
    log.info('building python'); start = time.time()
    try:
        path = extract_package('Python')
        cmd('./configure --prefix="%s"  --libdir="%s"/lib --enable-shared'%(PREFIX,PREFIX), path)
        cmd('make -j %s'%NCPU, path)
        cmd('make install', path)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_node():
    log.info('building node'); start = time.time()
    try:
        target = "node-v%s.tar.gz"%NODE_VERSION
        if not os.path.exists(os.path.join(SRC, target)):
            cmd('rm -f node-v*.tar.*', SRC)  # remove any source tarballs that might have got left around
            download("http://nodejs.org/dist/v%s/node-v%s.tar.gz"%(NODE_VERSION, NODE_VERSION))
        path = extract_package('node')
        if NODE_VERSION == "0.8.25":
            cmd('patch -p1 < %s/node-patch-backported-to-fix-hex-issue.patch'%PATCHES, path)
        cmd('./configure --prefix="%s"'%PREFIX, path)
        cmd('make -j %s'%NCPU, path)
        cmd('make install', path)
        cmd('git clone git://github.com/isaacs/npm.git && cd npm && make install', path)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_nginx():
    log.info('building nginx'); start = time.time()
    try:
        path = extract_package('nginx')
        cmd('./configure --prefix="%s"'%PREFIX, path)
        cmd('make -j %s'%NCPU, path)
        cmd('make install', path)
        cmd('mv sbin/nginx bin/', PREFIX)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_haproxy():
    log.info('building haproxy'); start = time.time()
    try:
        path = extract_package('haproxy')

        # patch log.c so it can write the log to a file instead of syslog
        cmd('patch -p0 < %s/haproxy.patch'%PATCHES, path)  # diff -Naur src/log.c  ~/log.c > ../patches/haproxy.patch
        cmd('make -j %s TARGET=%s'%(NCPU, 'linux2628' if OS=="Linux" else 'generic'), path)
        cmd('cp haproxy "%s"/bin/'%PREFIX, path)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_stunnel():
    log.info('building stunnel'); start = time.time()
    try:
        path = extract_package('stunnel')
        cmd('./configure --prefix="%s"'%PREFIX, path)
        cmd('make -j %s'%NCPU, path)
        cmd('make install < /dev/null', path)  # make build non-interactive -- I don't care about filling in a form for a demo example
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_cassandra():
    log.info('installing cassandra'); start = time.time()
    try:
        target = 'dsc-cassandra-%s.tar.gz'%CASSANDRA_VERSION
        if not os.path.exists(os.path.join(SRC, target)):
            cmd('rm -f dsc-cassandra-*.tar.*', SRC)  # remove any source tarballs that might have got left around
            download('http://downloads.datastax.com/community/dsc-cassandra-%s-bin.tar.gz'%CASSANDRA_VERSION)
            cmd('mv dsc-cassandra-%s-bin.tar.gz dsc-cassandra-%s.tar.gz'%(CASSANDRA_VERSION, CASSANDRA_VERSION), SRC)
        path = extract_package('dsc-cassandra')
        target2 = os.path.join(PREFIX, 'cassandra')
        print target2
        if os.path.exists(target2):
            shutil.rmtree(target2)
        os.makedirs(target2)
        print "copying over"
        cmd('cp -rv * "%s"'%target2, path)
        cmd('cp -v "%s/start-cassandra" "%s"/'%(PATCHES, os.path.join(PREFIX, 'bin')), path)
        print "making symlink so can use fast JNA java native thing"
        cmd("ln -sf /usr/share/java/jna.jar %s/local/cassandra/lib/"%DATA, path)

        print "building python library"
        cmd("cd pylib && python setup.py install", path)

        print "CASSANDRA IMPORTANT -- you might need to apply the patch from https://issues.apache.org/jira/browse/CASSANDRA-5895    !?!?"
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_python_packages():
    log.info('building python_packages'); start = time.time()
    try:
        target = 'setuptools-%s.tar.gz'%SETUPTOOLS_VERSION
        if not os.path.exists(os.path.join(SRC, target)):
            cmd("rm -f setuptools-*.tar.*", SRC)
            download("https://pypi.python.org/packages/source/s/setuptools/%s"%target)
        os.system("rm -rf %s/local/lib/python2.7/site-packages/setuptools-*"%DATA)
        path = extract_package('setuptools')
        cmd('python setup.py install', path)
        cmd('easy_install pip', path)
        for pkg in PYTHON_PACKAGES:
            cmd('pip install %s'%pkg, '/tmp')
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_bup():
    log.info('building bup'); start = time.time()
    try:
        path = extract_package('bup')
        cmd('./build', path)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_node_proxy():
    log.info('building node-proxy module'); start = time.time()
    try:
        cmd('git clone https://github.com/nodejitsu/node-http-proxy.git -b caronte; npm install node-http-proxy/; rm -rf node-http-proxy', PWD)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

def build_node_modules():
    log.info('building node_modules'); start = time.time()
    try:
        cmd('npm install %s'%(' '.join(NODE_MODULES)), PWD)
    finally:
        log.info("total time: %.2f seconds", time.time()-start)
        return time.time()-start

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Build packages from source")

    parser.add_argument('--build_all', dest='build_all', action='store_const', const=True, default=False,
                        help="build everything")

    parser.add_argument('--build_tinc', dest='build_tinc', action='store_const', const=True, default=False,
                        help="build tinc")

    parser.add_argument('--build_python', dest='build_python', action='store_const', const=True, default=False,
                        help="build the python interpreter")

    parser.add_argument('--build_node', dest='build_node', action='store_const', const=True, default=False,
                        help="build node")

    parser.add_argument('--build_nginx', dest='build_nginx', action='store_const', const=True, default=False,
                        help="build the nginx web server")

    parser.add_argument('--build_haproxy', dest='build_haproxy', action='store_const', const=True, default=False,
                        help="build the haproxy server")

    parser.add_argument('--build_stunnel', dest='build_stunnel', action='store_const', const=True, default=False,
                        help="build the stunnel server")

    parser.add_argument('--build_cassandra', dest='build_cassandra', action='store_const', const=True, default=False,
                        help="build the cassandra database server")

    parser.add_argument('--build_node_modules', dest='build_node_modules', action='store_const', const=True, default=False,
                        help="install all node packages")

    parser.add_argument('--build_node_proxy', dest='build_node_proxy', action='store_const', const=True, default=False,
                        help="install proxy node module")

    parser.add_argument('--build_python_packages', dest='build_python_packages', action='store_const', const=True, default=False,
                        help="install all Python packages")

    parser.add_argument('--build_bup', dest='build_bup', action='store_const', const=True, default=False,
                        help="install bup (git-style incremental compressed snapshots)")

    args = parser.parse_args()

    try:
        times = {}
        if args.build_all or args.build_tinc:
            times['tinc'] = build_tinc()

        if args.build_all or args.build_python:
            times['python'] = build_python()

        if args.build_all or args.build_node:
            times['node'] = build_node()

        if args.build_all or args.build_node_modules:
            times['node_modules'] = build_node_modules()

        if args.build_all or args.build_node_proxy:
            times['node_proxy'] = build_node_proxy()

        if args.build_all or args.build_nginx:
            times['nginx'] = build_nginx()

        if args.build_all or args.build_haproxy:
            times['haproxy'] = build_haproxy()

        if args.build_all or args.build_stunnel:
            times['stunnel'] = build_stunnel()

        if args.build_all or args.build_cassandra:
            times['cassandra'] = build_cassandra()

        if args.build_all or args.build_python_packages:
            times['python_packages'] = build_python_packages()

        if args.build_all or args.build_bup:
            times['bup'] = build_bup()

    finally:
        if times:
            log.info("Times: %s", times)
