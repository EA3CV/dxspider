DXWEB Y DXWEB ADMIN - INSTALACION, ACTUALIZACION Y RECUPERACION
================================================================

Edicion para revision: 27 de octubre de 2026
Gestor verificado: dxweb-manager.pl v0.49
Aplicaciones probadas: DXWeb 3.0.1 y DXWeb Admin 1.0.3

1. OBJETO Y ALCANCE
------------------

Este es el unico manual de instalacion de DXWeb y DXWeb Admin.
Ambas aplicaciones forman parte del arbol Git de DXSpider en /spider.
El procedimiento normal utiliza dxweb/dxweb-manager.pl. El gestor
configura servicios systemd y, opcionalmente, un ejemplo Nginx. NO
copia ni actualiza los archivos de las aplicaciones: estos proceden
exclusivamente del arbol Git existente.

La instalacion directa es el modo predeterminado y el validado.
No necesita Nginx. Nginx se documenta como ejemplo tecnico sin
soporte oficial de proxy inverso; no se ha revalidado en esta
version.

Ejecutar las operaciones de instalacion como root, sin sudo.
El usuario que ejecuta el gestor no tiene por que ser el usuario de
los servicios. Se recomienda sysop:spider cuando tenga los permisos
necesarios. El gestor puede conservar la identidad de unidades ya
instaladas o heredarla del servicio DXSpider. Para fijarla de forma
explicita, usar --user sysop --group spider.

2. ARCHIVOS Y DIAGRAMAS
----------------------

  /spider/INSTALL_DXWEB.es          Manual en espanol
  /spider/INSTALL_DXWEB.en          Manual en ingles britanico
  /spider/dxweb/dxweb-manager.pl    Gestor de servicios
  /spider/dxweb/install.pl          Instalador de copia de arbol
  /spider/dxweb/                    Aplicacion DXWeb
  /spider/dxweb-admin/              Aplicacion DXWeb Admin

Esquema de configuracion en espanol:
  /spider/dxweb/docs/DXWeb_Configuration_ES.png

El esquema debe comprobarse frente a los puertos y modos descritos
aqui antes de utilizarlo como referencia de despliegue.

El instalador dxweb/install.pl tiene otra finalidad: copia un arbol
fuente de DXWeb a un destino y conserva el anterior. No utilizarlo
para una actualizacion normal del codigo ya integrado en /spider.

3. MODOS Y PUERTOS
-----------------

  Modo                 DXWeb          Admin          DXSpider IntMsg
  -------------------  -------------- -------------- ---------------
  DIRECTO HTTP         0.0.0.0:7380   0.0.0.0:7381   127.0.0.1:27754
  NGINX, backend HTTP  127.0.0.1:7480 127.0.0.1:7481 127.0.0.1:27754
  NGINX, publico       puerto 7380    puerto 7381    no publicado

En modo directo, --scheme https configura TLS en las aplicaciones.
En modo Nginx, --scheme https configura TLS en el proxy, mientras
las aplicaciones siguen atendiendo HTTP en loopback.

El puerto 27754 no es un puerto para navegadores.
El valor predeterminado es 127.0.0.1:27754. Una actualizacion
conserva DXS_HOST y DXS_PORT de las unidades existentes.

4. COMPROBACIONES PREVIAS
-------------------------

Ejecutar como root desde el servidor DXSpider.

  cd /spider || exit 1
  ls -ld dxweb dxweb-admin
  perl -c dxweb/dxweb-manager.pl
  perl dxweb/dxweb-manager.pl --help
  id sysop
  getent group spider

Si se utiliza otra cuenta para los servicios, comprobar
esa cuenta y su grupo en lugar de sysop:spider.

No continuar si faltan los componentes, los permisos necesarios o
la comprobacion de sintaxis falla. No descartar cambios locales para
forzar una actualizacion. Revisar la identidad real de los servicios:

  systemctl cat dxspider.service
  systemctl cat dxweb.service
  systemctl cat dxweb-admin.service

Es normal que las dos ultimas unidades no existan en la primera
instalacion. No cambiar la identidad de servicios existentes sin
comprobar antes acceso a /spider y a los datos operativos necesarios.

5. PRIMERA INSTALACION DIRECTA HTTP
----------------------------------

Primero revisar el plan, que no modifica servicios:

  cd /spider || exit 1
  perl dxweb/dxweb-manager.pl --action plan \
    --root /spider --components both --mode direct \
    --scheme http --user sysop --group spider

Si el plan coincide con lo esperado, instalar:

  perl dxweb/dxweb-manager.pl --action install \
    --root /spider --components both --mode direct \
    --scheme http --user sysop --group spider --apply

El gestor crea o actualiza las unidades systemd. No hay que copiar
manualmente archivos .service del repositorio.

6. ACTUALIZACION DIRECTA
-----------------------

DXWeb y DXWeb Admin forman parte del repositorio de DXSpider.
Sus archivos se actualizan junto con el resto del proyecto
mediante el procedimiento habitual de actualizacion de DXSpider.

No es necesario descargar ni actualizar estos componentes
por separado.

Despues de actualizar DXSpider, si DXWeb o DXWeb Admin han
cambiado, ejecutar el gestor de instalacion siguiendo el
procedimiento de la seccion 5.

Primero revisar el plan y, si es correcto, aplicar los cambios.

El gestor actualiza la configuracion de los servicios cuando
es necesario y los reinicia para utilizar el codigo actualizado.

No es necesario reiniciar DXSpider para aplicar exclusivamente
una actualizacion de DXWeb o DXWeb Admin.

7. INSTALACION Y ACTUALIZACION CON NGINX
---------------------------------------

EJEMPLO NO SOPORTADO OFICIALMENTE. El gestor v0.49 puede generar
configuracion Nginx en el mismo host que DXWeb y DXWeb Admin. No se
ha validado aqui un proxy en otro servidor ni el uso en subrutas.

Comprobar que Nginx existe, revisar su configuracion y respaldarla:

  cd /spider || exit 1
  nginx -t
  ls -la /etc/nginx/sites-enabled/
  mkdir -p /root/dxweb-nginx-backup
  cp -a /etc/nginx/nginx.conf /root/dxweb-nginx-backup/
  cp -a /etc/nginx/sites-available /root/dxweb-nginx-backup/
  cp -a /etc/nginx/sites-enabled /root/dxweb-nginx-backup/

No borrar ni sobrescribir sitios ajenos. Si ya existe el sitio
/etc/nginx/sites-enabled/dxweb.conf, el gestor rechaza la instalacion
Nginx y exige migracion manual. No forzarla eliminando configuracion.

Para HTTP, sustituir web.example.net por el nombre DNS real:

  perl dxweb/dxweb-manager.pl --action plan \
    --root /spider --components both --mode nginx \
    --scheme http --hostname web.example.net \
    --user sysop --group spider

  perl dxweb/dxweb-manager.pl --action install \
    --root /spider --components both --mode nginx \
    --scheme http --hostname web.example.net \
    --user sysop --group spider --apply

Para HTTPS se necesitan certificado y clave privada reales, que
coincidan y cubran el hostname. El gestor comprueba estos datos:

  perl dxweb/dxweb-manager.pl --action plan \
    --root /spider --components both --mode nginx \
    --scheme https --hostname web.example.net \
    --cert /etc/ssl/dxweb/fullchain.pem \
    --key /etc/ssl/dxweb/privkey.pem \
    --user sysop --group spider

  perl dxweb/dxweb-manager.pl --action install \
    --root /spider --components both --mode nginx \
    --scheme https --hostname web.example.net \
    --cert /etc/ssl/dxweb/fullchain.pem \
    --key /etc/ssl/dxweb/privkey.pem \
    --user sysop --group spider --apply

Las rutas de certificados son ejemplos; no usarlas literalmente.
El gestor no emite certificados. La configuracion Nginx generada se
guarda en /etc/nginx/sites-available/dxweb-installer.conf y su enlace
en /etc/nginx/sites-enabled/dxweb-installer.conf.

El gestor genera dos bloques de servidor en puertos 7380 y 7381,
con proxy a 127.0.0.1:7480 y 127.0.0.1:7481. Configura Upgrade para
WebSocket y cabeceras de proxy. Mantener inaccesibles desde fuera
los puertos internos. No confiar en cabeceras remitidas por clientes.

CONFIGURACION MANUAL DE UN PROXY INVERSO HTTP

Cuando DXWeb o DXWeb Admin se configuran manualmente detras de
un proxy inverso HTTP, establecer MOJO_REVERSE_PROXY=1 en el
servicio correspondiente. El proxy debe transmitir la IP real
del cliente mediante X-Real-IP o X-Forwarded-For.

Aceptar estas cabeceras unicamente desde proxies de confianza,
para evitar que un cliente falsifique su direccion IP. Comprobar
que DXWeb identifica correctamente la IP real del usuario, ya
que una IP incorrecta puede afectar a la aceptacion de spots
por otros nodos.

El gestor configura automaticamente MOJO_REVERSE_PROXY=1 y las
cabeceras necesarias cuando se utiliza --mode nginx. Estas
indicaciones manuales son para otros proxies o instalaciones
realizadas sin el gestor.

Para actualizar una instalacion Nginx, conservar hostname, esquema,
certificado y clave. Revisar primero el plan y despues aplicar.
No mezclar un servicio directo con el proxy Nginx sin migracion.

8. INSTALAR SOLO UNA APLICACION
------------------------------

En modo directo puede elegirse --components dxweb o --components
admin, en lugar de both. Mantener los demas argumentos del plan y
de la instalacion. En modo Nginx, el gestor puede preservar el bloque
del otro componente cuando existe una configuracion gestionada por
el propio instalador y con el formato exacto que este reconoce.
Para una primera instalacion Nginx se recomienda --components both.

9. COMPROBACION DEL RESULTADO
----------------------------

  cd /spider || exit 1
  perl dxweb/dxweb-manager.pl --action status --components both
  systemctl is-active dxweb.service dxweb-admin.service
  systemctl show dxweb.service -p ActiveState -p MainPID
  systemctl show dxweb-admin.service -p ActiveState -p MainPID
  ss -lntp | grep -E ':(7380|7381|7480|7481)\b'

En instalacion directa HTTP:

  curl -f http://127.0.0.1:7380/software-version.json
  curl -f http://127.0.0.1:7381/software-versions.json

En modo Nginx, comprobar nginx -t y utilizar la URL publica real
con su esquema http o https y los puertos 7380 y 7381.
Comprobar en un navegador los spots, autenticacion de SYSOP,
WebSockets, supervision, filtros y permisos administrativos.
Una respuesta HTTP correcta no sustituye estas comprobaciones.

10. RESPALDOS Y ROLLBACK
-----------------------

El gestor guarda las transacciones de configuracion modificada en:

  /var/backups/dxweb-installer/

Conservar el nombre exacto de la transaccion. Antes de revertir,
examinar su manifest.json y el plan de rollback. Ejemplo:

  cd /spider || exit 1
  ls -lt /var/backups/dxweb-installer/
  perl dxweb/dxweb-manager.pl --action rollback \
    --backup /var/backups/dxweb-installer/TRANSACCION

Solo despues de revisar el resultado, ejecutar:

  perl dxweb/dxweb-manager.pl --action rollback \
    --backup /var/backups/dxweb-installer/TRANSACCION --apply

El rollback restaura configuracion y estado de servicios; NO cambia
la revision del codigo Git. Si la transaccion corresponde a una
instalacion inicial, el resultado correcto puede ser la retirada de
las unidades systemd: LoadState=not-found y ActiveState=inactive.
El gestor usa parada acotada y un checkpoint de seguridad durante
la recuperacion. No repetir el rollback ni restaurar unidades a mano
sin inspeccionar antes el estado resultante y los registros.

No borrar bases de datos, filtros, certificados ni configuraciones
locales como supuesto procedimiento de recuperacion.

11. REGISTROS Y DIAGNOSTICO
--------------------------

  journalctl -u dxweb.service -n 100 --no-pager
  journalctl -u dxweb-admin.service -n 100 --no-pager
  systemctl status dxweb.service --no-pager
  systemctl status dxweb-admin.service --no-pager

Con Nginx, comprobar ademas:

  nginx -t
  journalctl -u nginx.service -n 100 --no-pager

Si el gestor detecta un sitio Nginx incompatible, no borrar la
configuracion existente. Preparar una migracion con respaldo previo.
Si indica NO CONFIG CHANGES, aun puede ser necesario ejecutar
install --apply tras actualizar el codigo Git.

12. EJEMPLOS TECNICOS DE SYSTEMD
--------------------------------

Se pueden distribuir cuatro ejemplos independientes:

  dxweb.service.example
  dxweb-admin.service.example
  dxweb.service.nginx.example
  dxweb-admin.service.nginx.example

Son referencias para pruebas manuales, NO pasos de instalacion.
El gestor genera directamente las unidades instaladas y conserva
algunas opciones locales preexistentes. Por ello los ejemplos deben
representar una instalacion nueva, con sysop:spider, /spider como
ruta real y DXS_HOST=127.0.0.1, DXS_PORT=27754. Si /spider es un
enlace simbolico, el gestor usa la ruta fisica resuelta; los ejemplos
requieren ajustar esa ruta antes de una instalacion manual.

Los ejemplos se verificaran contra el generador de unidades antes
de incorporarlos al repositorio. No sustituir una unidad operativa
por un ejemplo sin respaldo y sin comprobar sus diferencias.

13. LIMITACIONES Y SEGURIDAD
----------------------------

Se recomienda utilizar HTTPS siempre que DXWeb o DXWeb Admin
sean accesibles desde Internet o desde redes publicas.

Esta recomendacion es especialmente importante para DXWeb
Admin, ya que permite acceder a funciones administrativas
y requiere autenticacion.

HTTP sin cifrado debe reservarse para redes locales de
confianza o entornos de pruebas controlados.

El soporte de Nginx se proporciona como ejemplo de
configuracion, sin garantia de compatibilidad para todos
los escenarios. Los proxies externos, las subrutas y los
certificados deben validarse por separado.

No modificar recursivamente propietarios o permisos de
/spider para resolver problemas de acceso.

La instalacion no requiere detener ni reinstalar DXSpider.
No usar este manual para administrar otros proyectos del nodo.
