{ pkgs, config, ... }:

with pkgs.lib;

let
  genSSLVHost = vhost: configuration: let
    genConf = sock: {
      type = "static";
      on = vhost.fqdn;
      socket = "${sock}:443";

      socketConfig = ''
        ssl.engine  = "enable"
        ssl.pemfile = "${vhost.ssl.privateKey.path}"
        ssl.ca-file = "${vhost.ssl.intermediateCert}"
      '';

      inherit configuration;
    };
  in [ (genConf vhost.ipv4) (genConf "[${vhost.ipv6}]") ];
in {
  imports = [ ../hydra.nix ../lighttpd.nix ../domains.nix ];

  boot.kernelPackages = pkgs.linuxPackages_3_10;

  fileSystems."/".options = concatStringsSep "," [
    "autodefrag"
    "space_cache"
    "inode_cache"
    "compress=lzo"
    "noatime"
  ];

  services.headcounter.lighttpd = {
    enable = true;

    modules.proxy.enable = true;
    modules.magnet.enable = true;
    modules.setenv.enable = true;
    modules.redirect.enable = true;

    virtualHosts = with config.vhosts; genSSLVHost headcounter ''
      $HTTP["url"] =~ "^/hydra(?:$|/)" {
        magnet.attract-physical-path-to = ( "${pkgs.writeText "rewrite.lua" ''
        if string.sub(lighty.env["request.uri"], 1, 6) == "/hydra" then
          lighty.env["request.uri"] = string.sub(lighty.env["request.uri"], 7)
        end
        ''}" )
        setenv.add-request-header = (
          "X-Request-Base" => "https://headcounter.org/hydra/"
        )
        proxy.balance = "hash"
        proxy.server = ("/hydra" => ((
          "host" => "127.0.0.1",
          "port" => 3000
        )))
      } # http://redmine.lighttpd.net/issues/1268
      else $HTTP["url"] =~ "" {
        url.redirect = ( "^/(.*)" => "https://jabber.headcounter.org/$1" )
      }
    '' ++ singleton {
      socket = ":80";
      socketConfig = ''
        url.redirect = ( "^/(.*)" => "https://jabber.headcounter.org/$1" )
      '';
    };
  };
}