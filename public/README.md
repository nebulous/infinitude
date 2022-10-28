# Infinitude

Client-side of Infinitude

To make frontend changes, make them in app/ and use Grunt/Bower to rebuild

    bower install
    grunt bowerInstall
    grunt build

If you have disk space and don't wish to engage with npm hell, a docker image is recommended:

    docker run -v $PWD/public:/data --rm -it digitallyseamless/nodejs-bower-grunt bower install
    docker run -v $PWD/public:/data --rm -it digitallyseamless/nodejs-bower-grunt grunt bowerInstall
    docker run -v $PWD/public:/data --rm -it digitallyseamless/nodejs-bower-grunt grunt build

Or simply run build-dist.sh, which does all of the above

`~/infinitude/public$ sh build-dist.sh`

A working version of dist/ is included in the master and should not need to be regenerated under normal circumstances in production mode
