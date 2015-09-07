#!/bin/bash

# Bash settings
set -e
set -u

# Set the sticky bit.
chmod 1777 /data/

export USERNAME=$(curl --silent http://169.254.169.254/metadata/v1/user/username)
export DOMAIN=$(curl --silent http://169.254.169.254/metadata/v1/domains/public/0/name)
export GATEWAY=$(curl --silent http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/gateway)
export PASSWORD_FILE="/data/pw"

URI=$(curl --silent http://169.254.169.254/metadata/v1/paths/public/0/uri)
if [ "/" != "${URI: -1}" ] ; then
    URI="$URI/"
fi
export URI

# mysql
# echo "alias /var/lib/mysql/ -> /data/mysql," >> /etc/apparmor.d/tunables/alias
# sudo /etc/init.d/apparmor reload
service apparmor teardown
apt-get -y purge apparmor
mkdir -p /etc/mysql/conf.d
cat <<MYSQL > /etc/mysql/conf.d/portal.cnf
[mysqld]
datadir = /data/mysql

MYSQL

#
# Packages
#
export DEBIAN_FRONTEND=noninteractive
apt-key adv --keyserver keyserver.ubuntu.com --recv 80F70E11F0F0D5F10CB20E62F5DA5F09C3173AA6
echo "deb http://ppa.launchpad.net/brightbox/ruby-ng/ubuntu trusty main" >> /etc/apt/sources.list
# apt-key adv --keyserver keyserver.ubuntu.com --recv 8B3981E7A6852F782CC4951600A6F0A3C300EE8C
# echo "deb http://ppa.launchpad.net/nginx/stable/ubuntu trusty main" >> /etc/apt/sources.list
apt-get update
apt-get install -y build-essential mysql-server libmysqlclient-dev pwgen git ruby2.1 ruby2.1-dev\
 libc6-dev zlib1g-dev libxml2-dev libmysqlclient18 libpq5 libyaml-0-2 libcurl3 libssl1.0.0 \
 libxslt1.1 libffi6 zlib1g gsfonts \
 imagemagick libmagickwand-dev bzr cvs mercurial subversion libcurl4-openssl-dev
# apt-get install nginx
# apt-get source nginx
apt-get install -y nodejs &&
ln -sf /usr/bin/nodejs /usr/local/bin/node
# phusionpassenger
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
sudo apt-get install -y apt-transport-https ca-certificates
sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger trusty main > /etc/apt/sources.list.d/passenger.list'
apt-get update

# Install Passenger + Nginx
sudo apt-get install -y nginx-extras passenger

#
# Generate admin password, if necessary.
#

if [ ! -e $PASSWORD_FILE ] ; then
  pwgen 10 1 > $PASSWORD_FILE
  export PASSWORD=$(cat $PASSWORD_FILE)
  echo "CREATE DATABASE redmine CHARACTER SET utf8;"|mysql
  echo "CREATE USER 'redmine'@'localhost' IDENTIFIED BY '$PASSWORD';"|mysql
  echo "GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'localhost';"|mysql
else
  export PASSWORD=$(cat $PASSWORD_FILE)
fi



#
# Clone/configure Redmine.
#
cd /opt
git clone https://github.com/redmine/redmine.git
cd redmine

cat <<CONFIG > config/database.yml
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: $PASSWORD
CONFIG

gem install --no-document bundler
# might not be needed / switch to chruby/ruby-install for sane versioning
gem install --no-document mysql2
bundle install --without development test
bundle exec rake generate_secret_token

RAILS_ENV=production bundle exec rake db:migrate

#
# passenger
#

#
# Nginx proxy.
#

cat <<NGINX > /etc/nginx/sites-available/default

passenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;
passenger_ruby /usr/bin/passenger_free_ruby;

server {
    listen 81;
    return 302 https://${DOMAIN}${URI};
}

server {
    listen 80;
    root /opt/redmine/public;
    passenger_enabled on;

    location $URI {
        alias /opt/redmine/public;
        passenger_base_uri /redmine;
        passenger_app_root /opt/redmine;
        passenger_document_root /opt/redmine/public;

        allow $GATEWAY;
        deny all;

        passenger_enabled on;

        client_max_body_size      50m; # Max attachemnt size

    }
}
NGINX

service nginx restart

#
# Sync files in memory to disk.
#
sync
