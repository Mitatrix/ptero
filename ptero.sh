#!/bin/bash

# Couleurs
NONE="\033[m"
WHITE="\033[1;37m"
GREEN="\033[1;32m"
RED="\033[0;32;31m"
YELLOW="\033[1;33m"
BLUE="\033[34m"
CYAN="\033[36m"
LIGHT_GREEN="\033[1;32m"
LIGHT_RED="\033[1;31m"
BOLD="\033[1m"
UNDERLINE="\033[4m"

# Vérifier s'il y a des arguments passés
if [ $# -eq 0 ]; then
    echo "Usage: $0 domaine=mondomaine.com mail=adresse@mail.com motdepasse=motdepasse"
    exit 1
fi

# Initialiser les variables en dehors de la boucle
domaine=""
mail=""
motdepasse=""
token=""

apt install jq -y > /dev/null 2>&1

# Parcourir les arguments
for arg in "$@"; do
    if [ "${arg%%=*}" == "domaine" ]; then
        domaine=${arg#*=}
        echo -e "${YELLOW}Le domaine est :${NONE} $domaine"
    fi

    if [ "${arg%%=*}" == "mail" ]; then
        mail=${arg#*=}
        echo -e "${YELLOW}L'adresse e-mail est :${NONE} $mail"
    fi

    if [ "${arg%%=*}" == "motdepasse" ]; then
        motdepasse=${arg#*=}
        echo -e "${YELLOW}Le mot de passe est :${NONE} $motdepasse"
    fi

    printf "\n"
done

# Vérifier si le domaine et le mot de passe ont été spécifiés
if [ -z "$mail" ] || [ -z "$motdepasse" ]; then
    echo "Erreur: Les paramètres 'mail' et 'motdepasse' sont obligatoires."
    exit 1
fi

if [ -n "$domaine" ]; then
    app_url="https://$domaine"
else
    domaine=$(curl ifconfig.me)
    app_url="http://$domaine"
fi

# PACKAGE
apt update
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg wget lsb-release sudo
apt-get -y install mailutils
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
wget -q https://packages.sury.org/php/apt.gpg -O- | sudo apt-key add -
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php.list
apt update -y
apt -y install php8.1 php8.1-common php8.1-cli php8.1-gd php8.1-mysql php8.1-mbstring php8.1-bcmath php8.1-xml php8.1-fpm php8.1-curl php8.1-zip mariadb-server nginx tar unzip git

# Preinstall Pterodactyl
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
export COMPOSER_HOME="/usr/local/bin/composer"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/download/v1.10.1/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Setup Artisan
email="$mail"
timezone=Europe/Paris
php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="file" \
    --session="database" \
    --queue="database" \
    --settings-ui=true
	
# Database
MYSQL_PASSWORD=$(openssl rand -base64 32)
MYSQLADMIN_PASSWORD=$(openssl rand -base64 32)
MYSQL_USER="pterodactyl"
MYSQLADMIN_USER="pterodactyluser"
MYSQL_DB="panel"
echo "${MYSQLADMIN_PASSWORD}" >> /root/mdp
MY_CNF_PATH="/etc/mysql/my.cnf"
echo "[mysqld]" >> $MY_CNF_PATH
echo "character-set-server=utf8mb4" >> $MY_CNF_PATH
echo "collation-server=utf8mb4_unicode_ci" >> $MY_CNF_PATH
systemctl restart mysql mariadb
mysql -u root -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -u root -e "CREATE DATABASE ${MYSQL_DB};"
mysql -u root -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"
mysql -u root -e "FLUSH PRIVILEGES;"
mysql -u root -e "CREATE USER '${MYSQLADMIN_USER}'@'%' IDENTIFIED BY '${MYSQLADMIN_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO '${MYSQLADMIN_USER}'@'%' WITH GRANT OPTION;"
php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQLADMIN_USER" \
    --password="$MYSQLADMIN_PASSWORD"
php artisan migrate --seed --force
user_email="$mail"
user_username="admin"
user_firstname="admin"
user_lastname="admin"
user_password="$motdepasse"
php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1
chown -R www-data:www-data /var/www/pterodactyl
crontab -l | {
  cat
  echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
} | crontab -
GITHUB_SOURCE="master"
GITHUB_BASE_URL="https://raw.githubusercontent.com/vilhelmprytz/pterodactyl-installer/$GITHUB_SOURCE"
DL_FILE="nginx.conf"
PHP_SOCKET="/run/php/php8.1-fpm.sock"
if [ -n "$domaine" ]; then
    apt-get install certbot python3-certbot-nginx -y
    certbot --nginx -d $domaine --agree-tos -m $mail -n
fi
curl -o /etc/systemd/system/pteroq.service $GITHUB_BASE_URL/configs/pteroq.service
chmod +x /etc/systemd/system/pteroq.service
systemctl enable pteroq.service --now
rm -rf /etc/nginx/sites-enabled/default
curl -o /etc/nginx/sites-available/pterodactyl.conf $GITHUB_BASE_URL/configs/$DL_FILE
sed -i -e "s@<domain>@${domaine}@g" /etc/nginx/sites-available/pterodactyl.conf
sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" /etc/nginx/sites-available/pterodactyl.conf
ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

# Wings
php artisan p:location:make --short="PAR3" --long="France"
apt-get remove docker docker-engine docker.io containerd runc
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod u+x /usr/local/bin/wings
curl -o /etc/systemd/system/wings.service $GITHUB_BASE_URL/configs/wings.service
systemctl daemon-reload
sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb
MEMORY=$(free -m | awk 'NR==2{printf "%s", $2 }')
STORAGE=$(df -m | awk '$NF=="/"{printf "%d", $4}')
php artisan p:node:make \
    --name "Node" \
    --description="Propulsé par CLIENTXCMS" \
    --locationId=1 \
    --fqdn=${domaine} \
    --public=1 \
    --scheme=http \
    --proxy=0 \
    --maintenance=0 \
    --maxMemory=${MEMORY} \
    --overallocateMemory=0 \
    --maxDisk=${STORAGE} \
    --overallocateDisk=0 \
    --uploadSize=100 \
    --daemonListeningPort=8443 \
    --daemonSFTPPort=2022 \
    --daemonBase=/var/lib/pterodactyl/volumes
echo "$(php artisan p:node:configuration 1)" >> /etc/pterodactyl/config.yml
systemctl enable --now wings

# Ajout automatique de la base de données dans Pterodactyl
php artisan p:db:make --name="$MYSQL_DB" --host="127.0.0.1" --port=3306 --username="$MYSQLADMIN_USER" --password="$MYSQLADMIN_PASSWORD" --database="panel" --remote=0 --max=10

# Finalisation de l'installation
cd /var/www/pterodactyl/resources/scripts/routers
wget https://cdn.discordapp.com/attachments/1068590217738596432/1197619361209385052/ServerRouter.ts
cd /var/www/pterodactyl
systemctl restart mysql
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force
systemctl restart mysql
chown -R www-data:www-data /var/www/pterodactyl/*
php artisan queue:restart
php artisan up
rm -rf /root/mdp
rm -rf /ptero

# Informations de fin d'installation
echo -e "${GREEN}INSTALLATION REUSSIE"
echo -e "${YELLOW}Le mot de passe est :${NONE} $motdepasse"
echo -e "${YELLOW}L'adresse e-mail est :${NONE} $mail"
echo -e "${YELLOW}Le domaine est :${NONE} $domaine"
echo -e "${YELLOW}Accès DB :${NONE} $MYSQLADMIN_USER"
echo -e "${YELLOW}Mot de passe DB :${NONE} $MYSQLADMIN_PASSWORD"
echo -e "${GREEN}INSTALLATION REUSSIE"
history -c
