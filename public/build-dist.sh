CURRENT_UID=$(id -u):$(id -g)
docker run -u $CURRENT_UID -e HOME=/tmp -v $PWD:/data --rm -it digitallyseamless/nodejs-bower-grunt bower install
docker run -u $CURRENT_UID -e HOME=/tmp -v $PWD:/data --rm -it digitallyseamless/nodejs-bower-grunt grunt bowerInstall
docker run -u $CURRENT_UID -e HOME=/tmp -v $PWD:/data --rm -it digitallyseamless/nodejs-bower-grunt grunt build

sed -i.bak "s/\/bower_components\/bootstrap\/dist//g" dist/styles/*.vendor.css
sed -i.bak "s/\/bower_components\/fontawesome//g" dist/styles/*.vendor.css
