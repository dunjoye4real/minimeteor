#!/bin/sh

# Show program info when no arguments were given
if [ "$#" -eq 0 ]; then
    echo Usage: $0 dockertags
    exit
fi

# The project directory is always the current directory
PROJECTDIR=.

# Create a temporary directory
TEMPDIR=`mktemp -d`
echo Using temp dir: ${TEMPDIR}

# Assemble a list of Docker tags
DOCKERTAG=""
for arg in "$@"
do
  DOCKERTAG="$DOCKERTAG -t $arg"
done

# Containers will use the current user's id to perform non-root tasks (unless the user is root)
USERID=`id -u`
USERNAME="user"
USERHOME="/home/$USERNAME"
ADDUSER_COMMAND="adduser -D -u $USERID -h $USERHOME $USERNAME"  # Alpine
USERADD_COMMAND="useradd --uid $USERID -m $USERNAME"  # Debian
SUDO="sudo -u $USERNAME"
if [ ${USERID} -eq 0 ]; then
    # uid==0 is root, don't try to pass uid to adduser/useradd
    ADDUSER_COMMAND="adduser -D -h $USERHOME $USERNAME"  # Alpine
    USERADD_COMMAND="useradd -m $USERNAME"  # Debian
fi

# Log to stdout
INFO="[minimeteor]"

echo ${INFO} Copying project files to temp directory
cp -r ${PROJECTDIR} ${TEMPDIR}/source


# ------------------------------
# Meteor build
# ------------------------------

echo ${INFO} Writing Meteor build script
cat >${TEMPDIR}/meteorbuild.sh <<EOM
#!/bin/sh
echo ${INFO} Meteor container started

echo ${INFO} Updating apt
apt-get -qq update
echo ${INFO} Installing tools
apt-get -qq install curl procps python g++ make sudo >/dev/null

echo ${INFO} Copying files
${USERADD_COMMAND}
cp -r /dockerhost/source ${USERHOME}
chown -R ${USERNAME} ${USERHOME}/source
cd ${USERHOME}/source

${SUDO} curl "https://install.meteor.com/" | sh

echo ${INFO} Installing NPM build dependencies
cd ${USERHOME}/source
${SUDO} meteor npm --loglevel=silent install

echo ${INFO} Performing Meteor build
${SUDO} meteor build --directory ${USERHOME}/build

echo ${INFO} Copying bundle from build container to temp directory
cp -r ${USERHOME}/build/bundle /dockerhost/bundle

echo ${INFO} Meteor container finished
EOM

echo ${INFO} Setting executable rights on build script
chmod +x ${TEMPDIR}/meteorbuild.sh
echo ${INFO} Starting Meteor container
docker run -v ${TEMPDIR}:/dockerhost --rm debian /dockerhost/meteorbuild.sh

# ------------------------------
# Get Node version
# ------------------------------
NODE_VERSION=`sed 's/v//g' ${TEMPDIR}/bundle/.node_version.txt`

# ------------------------------
# Alpine build
# ------------------------------

echo ${INFO} Writing Alpine build script
cat >$TEMPDIR/alpinebuild.sh <<EOM
#!/bin/sh
echo ${INFO} Alpine container started, installing tools
apk add --no-cache make gcc g++ python sudo

echo ${INFO} Copying project into build container
${ADDUSER_COMMAND}
cp -r /dockerhost/bundle ${USERHOME}/bundle
chown -R ${USERNAME} ${USERHOME}/bundle

echo ${INFO} Installing NPM build dependencies
cd ${USERHOME}/bundle/programs/server
${SUDO} npm install

echo ${INFO} Copying bundle to temp directory from inside of the build container
cp -r ${USERHOME}/bundle /dockerhost/bundle-alpine

echo ${INFO} Meteor container finished
EOM

echo ${INFO} Setting executable rights on Alpine build script
chmod +x ${TEMPDIR}/alpinebuild.sh
echo ${INFO} Starting Alpine build container
docker run -v ${TEMPDIR}:/dockerhost --rm mhart/alpine-node:${NODE_VERSION} /dockerhost/alpinebuild.sh


# ------------------------------
# Docker image build
# The final image always creates a non-root user.
# ------------------------------

echo ${INFO} Writing Dockerfile
cat >${TEMPDIR}/bundle-alpine/Dockerfile <<EOM
# Dockerfile
FROM mhart/alpine-node:${NODE_VERSION}
RUN adduser -D -h /home/user user
ADD . /home/user
WORKDIR /home/user
ENV PORT 3000
EXPOSE 3000
USER user
CMD node main.js
EOM
echo ${INFO} Starting docker build
docker build ${DOCKERTAG} ${TEMPDIR}/bundle-alpine

# Removes temp directory
echo ${INFO} Removing temp directory ${TEMPDIR}
rm -rf ${TEMPDIR}

echo ${INFO} Build finished.
