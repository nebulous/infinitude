# State directory

By default Infinitude will store thermostat state files in this directory in JSON and XML formats.

To change the directory used, specify the $config->{store_base} key in the infinitude script.
Any get(key) set(key,value) store should work with Infinitude. If you would prefer to use a
different persistence mechanism, assign the $store object to one of your choosing.
