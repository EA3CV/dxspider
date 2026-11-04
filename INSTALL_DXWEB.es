DXWEB Y DXWEB ADMIN - INSTALACION, ACTUALIZACION Y RECUPERACION
================================================================
Manual operativo en espanol.
Revision de 4 de noviembre de 2026.

1. OBJETO, ARQUITECTURA Y ALCANCE
---------------------------------
Este es el manual de instalacion y gestion para el SYSOP. El unico
punto de entrada interactivo documentado es:

  cd /spider
  perl dxweb/dxweb-menu.pl

El menu utiliza internamente el motor transaccional existente para
planificar, instalar, consultar el estado y recuperar configuraciones.
El SYSOP NO tiene que ejecutar directamente ese motor. El menu no
copia ni actualiza codigo de las aplicaciones: DXWeb y DXWeb Admin
proceden del arbol Git de DXSpider.

DXWeb y DXWeb Admin son aplicaciones distintas: se pueden instalar,
configurar y gestionar individualmente o conjuntamente. Turnstile
protege el login de ambas en las versiones probadas DXWeb 4.0.3 y
DXWeb Admin 2.0.3; DXWeb tambien protege el registro publico.
La proteccion no sustituye la contrasena ni la autorizacion SYSOP.

2. ARCHIVOS, REQUISITOS Y PREPARACION
-------------------------------------
  /spider/dxweb/dxweb-menu.pl              Interfaz unica para el SYSOP
  /spider/dxweb/dxweb-manager.pl           Motor interno existente
  /spider/dxweb/tools/turnstile-config.pl  Configuracion Turnstile
  /spider/INSTALL_DXWEB.es                 Este manual
  /spider/dxweb/                           Aplicacion DXWeb
  /spider/dxweb-admin/                     Aplicacion DXWeb Admin

El instalador dxweb/install.pl copia un arbol fuente a otro destino;
NO es el procedimiento normal de configuracion de servicios.
El diagrama previo se conserva en
/spider/dxweb/docs/DXWeb_Configuration_ES.png; comprobar los puertos
antes de emplearlo para una instalacion concreta.

Como root en el servidor DXSpider, comprobar:

  cd /spider || exit 1
  ls -ld dxweb dxweb-admin
  perl -c dxweb/dxweb-menu.pl
  perl -c dxweb/dxweb-manager.pl
  perl -c dxweb/tools/turnstile-config.pl
  systemctl cat dxspider.service
  systemctl cat dxweb.service
  systemctl cat dxweb-admin.service

Las dos ultimas unidades pueden no existir en una primera instalacion.
El motor conserva la identidad de servicios existentes o intenta
heredarla del servicio DXSpider. El menu permite indicar usuario y
grupo explicitos cuando corresponda. Comprobar antes que existen:

  id sysop
  getent group spider

Son ejemplos: no presuponer que todos los sistemas utilizan sysop:spider.
No cambiar recursivamente permisos ni propietarios de /spider.

3. MENU PRINCIPAL Y ORDEN DE TRABAJO
------------------------------------
Al ejecutar el comando de la seccion 1 aparece:

  1. DXWeb
  2. DXWeb Admin
  3. Both applications (ambas aplicaciones)
  4. Cloudflare Turnstile
  5. Rollback (recuperacion)
  6. Exit (salir)

En las opciones 1, 2 y 3 hay un submenu:
  1. Service status (estado del servicio)
  2. Plan / install / update (planificar, instalar, actualizar)
  3. Back (volver)

Secuencia para una primera instalacion:
  A. Verificar requisitos y codigo presente en /spider.
  B. Elegir 1, 2 o 3 segun las aplicaciones que se desean instalar.
  C. Elegir 2 para seleccionar modo y esquema; revisar el plan.
  D. Confirmar Apply SOLO si el plan es correcto.
  E. Configurar las claves de Turnstile en la opcion 4.
  F. Comprobar los servicios desde opcion 1 y realizar pruebas web.

Para actualizar: actualizar primero el codigo por el procedimiento
habitual del repositorio; abrir el menu, elegir el componente, revisar
el plan y aplicar. El menu gestiona configuracion y servicios, no Git.

4. ELECCION DEL DESPLIEGUE DESDE EL MENU
----------------------------------------
Dentro de Plan / install / update, el menu pregunta:

  Access: 1 Direct, 2 Nginx
  Scheme: 1 HTTP, 2 HTTPS

Si se elige HTTPS, solicita hostname publico, certificado y clave
privada existentes. Valida rutas y existencia antes de enviar el plan
al motor, que ademas comprueba la validez del certificado, que la
clave coincida y que cubra el hostname. No emite certificados.

El menu pregunta por la identidad de servicio:
  1. Conservar o detectar usuario/grupo existentes
  2. Indicar usuario y grupo expresamente

El motor realiza primero una simulacion (plan). El menu solo aplica
los cambios tras la confirmacion expresa del SYSOP. Si el plan falla,
no ofrece aplicar. La instalacion puede crear o actualizar servicios,
configurar Nginx si se eligio y reiniciar servicios afectados.

4.1. PRIMERA INSTALACION DIRECTA HTTP
-------------------------------------
Recomendado como caso base, sin Nginx. 
Seleccionar opcion 3 (ambas),
submenu 2, 
Direct y HTTP, identidad detectada o explicita segun el sistema. 
Revisar el plan y confirmar. 
Para una sola web, usar 1 o 2.

4.2. DIRECTO HTTPS
------------------
Seleccionar 1, 2 o 3, 
submenu 2, 
Direct y HTTPS. 
Indicar nombre DNS, certificado y clave existentes. 
El cifrado se termina en las propias aplicaciones. 
Verificar que el certificado incluye el hostname.

4.3. NGINX HTTP O HTTPS
-----------------------
Es un ejemplo tecnico sin soporte oficial general para proxies en
otros servidores ni subrutas. Antes de instalar:

  nginx -t
  ls -la /etc/nginx/sites-enabled/
  mkdir -p /root/dxweb-nginx-backup
  cp -a /etc/nginx/nginx.conf /root/dxweb-nginx-backup/
  cp -a /etc/nginx/sites-available /root/dxweb-nginx-backup/
  cp -a /etc/nginx/sites-enabled /root/dxweb-nginx-backup/

Elegir Nginx en el submenu y HTTP o HTTPS segun corresponda. Para
HTTPS aportar hostname, certificado y clave. El motor utiliza
/etc/nginx/sites-available/dxweb-installer.conf y su enlace en
sites-enabled, y genera proxies a los puertos internos 7480 y 7481.
No borrar sitios ajenos ni forzar la instalacion si detecta un sitio
incompatible (por ejemplo dxweb.conf preexistente). Para una primera
instalacion Nginx se recomienda elegir ambas aplicaciones. El motor
puede preservar el otro bloque en una actualizacion parcial cuando
reconoce exactamente la configuracion gestionada.

4.4. ACTUALIZACION Y UNA SOLA APLICACION
----------------------------------------
Seleccionar DXWeb o DXWeb Admin en el menu principal. 
Mantener modo,esquema, hostname y certificados de la instalacion operativa;
revisar las diferencias del plan. 
No mezclar Direct y Nginx sin planificar una migracion. 
Actualizar el codigo desde Git es un paso separado.
No es necesario reiniciar DXSpider para actualizar solo las webs.

5. CLOUDFLARE TURNSTILE: OBTENCION Y CONFIGURACION DE CLAVES
------------------------------------------------------------
Turnstile NO crea automaticamente las claves. 
El SYSOP debe obtenerlas de Cloudflare. Este es un paso imprescindible 
cuando la proteccion se activa. 
Se requiere acceso a la cuenta Cloudflare correspondiente.

5.1. SOLICITAR LAS CLAVES
-------------------------
  1. Abrir https://dash.cloudflare.com/ y entrar o crear cuenta.
  2. Abrir Turnstile y crear un widget (Add widget).
  3. Elegir el modo Managed.
  4. Registrar los nombres de host EXACTOS por los que accederan los
     navegadores a DXWeb y DXWeb Admin. Si comparten hostname con
     distintos puertos, registrar el hostname; los puertos no forman
     parte del nombre autorizado. Si son hostnames distintos, incluir
     ambos en la configuracion del widget cuando se permita.
  5. Para pruebas con tunel SSH y http://localhost:17380 y :17381,
     comprobar que localhost esta autorizado en la configuracion de
     Turnstile. 127.0.0.1 no equivale al hostname localhost.
  6. Copiar la Site Key (publica, utilizada por el navegador) y la
     Secret Key (privada, utilizada por el servidor para verificar).
  7. Mantener la Secret Key fuera de capturas, tickets, repositorios,
     logs, archivos publicos y comandos que puedan quedar en history.

5.2. GUARDAR Y ACTIVAR DESDE EL MENU
------------------------------------
Abrir el menu principal, opcion 4 (Cloudflare Turnstile):
  1. Setup instructions (instrucciones)
  2. Show configuration status (estado)
  3. Store / replace keys (guardar o sustituir claves)
  4. Enable Turnstile (activar)
  5. Disable Turnstile (desactivar)
  6. Back (volver)

Seleccionar 3 y confirmar. 
Introducir Site Key y Secret Key cuando el programa lo solicite. 
La entrada de Secret Key se oculta si se utiliza una terminal interactiva.
Las claves se almacenan en /etc/dxweb/turnstile.json con permisos 
restrictivos 0600; 
la configuracion se crea inicialmente DESACTIVADA. 
A continuacion elegir 4 para activar. 
Elegir 2 para comprobar CONFIGURED y ENABLED.
El script requiere root para modificar la configuracion.

La configuracion es compartida por las aplicaciones que leen ese
archivo. El menu no crea claves diferentes por aplicacion ni verifica
por si mismo que los hostnames registrados en Cloudflare sean validos.
Al cambiar claves o activar/desactivar, verificar si las aplicaciones
requieren reinicio para releer la configuracion; hacerlo de manera
controlada, sin reiniciar DXSpider.

5.3. COMPROBACION REAL DE TURNSTILE
-----------------------------------
Abrir las dos webs con su hostname autorizado. Comprobar que el widget
se muestra y puede completarse. En DXWeb probar login, logout y nuevo
login en la misma sesion; abrir una sesion nueva y comprobar la nueva
verificacion. Probar tambien el registro publico. En DXWeb Admin,
comprobar CAPTCHA antes del login y autorizacion administrativa
habitual (privilegios suficientes); el CAPTCHA no otorga privilegios.

Para diagnostico, comprobar las rutas /turnstile-config.json en cada
servidor: deben mostrar enabled y site_key publica, NUNCA secret_key.
Si no aparece el widget, revisar consola del navegador, carga del
script Cloudflare, hostname autorizado y errores de inicializacion.
Si la clave es incorrecta, no eludir el control: revisar la
configuracion y los registros. Un HTTP 200 o WS 101 no demuestra por
si solo que se pueda autenticar.

6. VERIFICACION Y PRUEBAS DE SEGURIDAD
--------------------------------------
En menu, elegir 1/2/3 y luego Service status. Verificar adicionalmente:

  systemctl is-active dxweb.service dxweb-admin.service
  systemctl show dxweb.service -p ActiveState -p MainPID
  systemctl show dxweb-admin.service -p ActiveState -p MainPID
  ss -lntp | grep -E ':(7380|7381|7480|7481)\b'

Para HTTP directo:
  curl -f http://127.0.0.1:7380/software-version.json
  curl -f http://127.0.0.1:7381/software-versions.json

Para Nginx, comprobar nginx -t y las URLs publicas. Probar login,
registro, WebSocket, spots, supervision y permisos.

7. RECUPERACION DESDE EL MENU
-----------------------------
Las transacciones se guardan normalmente en:
  /var/backups/dxweb-installer/

En el menu principal seleccionar 5 Rollback. Introducir la ruta
absoluta de la transaccion que contiene manifest.json. El menu
presenta primero el plan de recuperacion; solo despues solicita
confirmacion para aplicar. No revertir sin inspeccionar el plan.

El rollback restaura configuracion y estado de servicios, NO cambia
la revision Git del codigo. Si se revierte la primera instalacion,
las unidades pueden quedar ausentes. El motor crea un checkpoint de
seguridad y usa parada acotada. No repetir rollback a ciegas.
No borrar bases de datos, filtros ni certificados para recuperar.

8. REFERENCIA TECNICA: MODOS, PUERTOS Y CONFIGURACION
-----------------------------------------------------
8.1. MODOS Y PUERTOS
--------------------

  Modo                 DXWeb          Admin          DXSpider IntMsg
  -------------------  -------------- -------------- ---------------
  DIRECTO HTTP         0.0.0.0:7380   0.0.0.0:7381   127.0.0.1:27754
  NGINX, backend HTTP  127.0.0.1:7480 127.0.0.1:7481 127.0.0.1:27754
  NGINX, publico       puerto 7380    puerto 7381    no publicado

En modo directo, HTTPS configura TLS en las aplicaciones.
En modo Nginx, HTTPS configura TLS en el proxy, mientras
las aplicaciones siguen atendiendo HTTP en loopback.

El puerto 27754 no es un puerto para navegadores.
El valor predeterminado es 127.0.0.1:27754. Una actualizacion
conserva DXS_HOST y DXS_PORT de las unidades existentes.

8.2. VARIABLES DE CONFIGURACION Y PUERTOS
-----------------------------------------

Las variables siguientes se establecen como Environment= en las
unidades systemd. El gestor las genera segun el modo seleccionado.
No es necesario editarlas a mano si se utiliza el instalador.

  Variable              Aplicacion       Funcion
  --------------------  ---------------  -----------------------------
  DXS_HOST              Ambas            Host del listener IntMsg
  DXS_PORT              Ambas            Puerto del listener IntMsg
  HTTP_HOST             DXWeb            Direccion de escucha HTTP
  HTTP_PORT             DXWeb            Puerto de escucha HTTP
  DXWEB_HOST            DXWeb Admin      Direccion de escucha Admin
  DXWEB_PORT            DXWeb Admin      Puerto de escucha Admin
  DXWEB_CLIENT_PORT     DXWeb Admin      Puerto del backend DXWeb
  DXWEB_CLIENT_HOST     DXWeb Admin      Host de conexion con DXWeb
  DXWEB_CLIENT_SCHEME   DXWeb Admin      Esquema de conexion DXWeb
  DXWEB_SCHEME          Ambas            Esquema HTTP o HTTPS
  MOJO_REVERSE_PROXY    Ambas            Confianza en proxy HTTP
  DXSPIDER_ROOT         Ambas            Ruta del arbol DXSpider
  DXWEB_TLS_CERT        Ambas            Certificado TLS directo
  DXWEB_TLS_KEY         Ambas            Clave privada TLS directa

Valores habituales para una instalacion nueva:

  Variable              Directo HTTP     Con Nginx
  --------------------  ---------------  -----------------------------
  DXS_HOST              127.0.0.1        127.0.0.1
  DXS_PORT              27754            27754
  HTTP_HOST             0.0.0.0          127.0.0.1
  HTTP_PORT             7380             7480
  DXWEB_HOST            0.0.0.0          127.0.0.1
  DXWEB_PORT            7381             7481
  DXWEB_CLIENT_PORT     7380             7480
  MOJO_REVERSE_PROXY    0                1

DXS_HOST y DXS_PORT identifican el servicio IntMsg de DXSpider,
no el acceso HTTP del navegador. En una actualizacion, el gestor
conserva sus valores si ya figuran en las unidades instaladas.

HTTP_HOST y HTTP_PORT corresponden exclusivamente a DXWeb.
DXWEB_HOST y DXWEB_PORT corresponden a DXWeb Admin. La variable
DXWEB_CLIENT_PORT indica a Admin el puerto del backend DXWeb;
no debe confundirse con el puerto publico del proxy.

DXWEB_CLIENT_HOST y DXWEB_CLIENT_SCHEME se generan segun el modo
y el esquema elegidos. En modo Nginx, las aplicaciones escuchan
por HTTP en loopback, aunque el acceso publico utilice HTTPS.

MOJO_REVERSE_PROXY=0 corresponde al acceso directo y el valor 1
al acceso a traves de un proxy HTTP de confianza. Para una
configuracion manual, consultar la seccion 8.2 sobre cabeceras e IP
real del cliente. No activar esta confianza ante clientes directos.

DXWEB_TLS_CERT y DXWEB_TLS_KEY solo se incorporan cuando las
aplicaciones sirven HTTPS directamente. Con Nginx, el certificado
y la clave se configuran en el proxy, no en los backends HTTP.

Para comprobar los valores realmente instalados:

  systemctl cat dxweb.service
  systemctl cat dxweb-admin.service

Los ejemplos anteriores describen instalaciones nuevas. Las
unidades existentes pueden conservar valores locales distintos.

9. REGISTROS Y DIAGNOSTICO
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
Si aparece NO CONFIG CHANGES, puede seguir siendo necesario aplicar la instalacion desde el menu tras actualizar el codigo Git.

10. EJEMPLOS TECNICOS DE SYSTEMD
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

11. LIMITACIONES Y SEGURIDAD
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
