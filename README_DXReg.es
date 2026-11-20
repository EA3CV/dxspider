DXSpider Registration V2                                     20-11-2026
========================

INDICE
------
1. Instalacion
2. Configuracion
3. Comandos
   3.1 request/register
   3.2 show/register
   3.3 accept/register
   3.4 reject/register
   3.5 remove/register
4. Persistencia
5. Notificaciones
6. Dependencias
7. Notas
   7.1 Extension de integracion web

Sistema nativo de registro de usuarios de DXSpider, con almacenamiento
historico de solicitudes, gestion de contrasenas y notificaciones opcionales
por correo electronico y Telegram sin bloqueo.

1. Instalacion
--------------

Para las notificaciones por correo electronico y/o Telegram, los archivos de
plantillas deben estar presentes en:

  /spider/local_data/reg_templates/


2. Configuracion
----------------

Anadir los siguientes ajustes a /spider/local/DXVars.pm:

# Al activar el registro se fuerza:
#   $reqreg    = 1;
#   $passwdreq = 0;
#
# Cuando esta desactivado, DXReg no altera la configuracion tradicional
# reqreg/passwdreq de DXSpider.
$reg_enable = 1;

# Longitud usada solo para contrasenas generadas automaticamente.
# No impone una politica de longitud para las contrasenas elegidas
# por los usuarios.
$reg_password_length = 10;

# Directorio predeterminado de plantillas
$reg_template_dir = "$local_data/reg_templates";


Las notificaciones por correo electronico son opcionales. Para activarlas,
configurar tambien:

$reg_email_enable = 1;    # 0 = desactivado

$reg_email_smtp   = 'smtp.example.net';
$reg_email_port   = 465;
$reg_email_user   = 'sysop@example.net';
$reg_email_pass   = '...';
$reg_email_from   = 'sysop@example.net';
$reg_email_admin  = 'sysop@example.net';


Las notificaciones administrativas por Telegram tambien son opcionales.
Para activarlas:

$reg_telegram_enable = 1;    # 0 = desactivado

$reg_telegram_token  = '...';
$reg_telegram_chatid = '...';


El ejemplo completo de configuracion se suministra en:

  /spider/perl/DXVars.pm.issue

registration.json se crea automaticamente en el primer uso en:

  /spider/local_data/registration.json

DXReg NO genera ni sobrescribe el directorio de plantillas ni sus archivos.
Se suministran con este paquete para que el SYSOP pueda personalizarlos sin
que DXReg sustituya los cambios locales.

Cuando $reg_enable = 0, DXReg no modifica la configuracion habitual de
DXSpider de $reqreg / $passwdreq.

3. Comandos
-----------

Nombres de los comandos:

  request/register
  show/register
  accept/register
  reject/register
  remove/register

El comando independiente show/registered sigue mostrando las cuentas DXUser
registradas; NO muestra las solicitudes de DXReg.

Solo para la familia de comandos show, la segunda palabra debe escribirse
completa como register o registered.
Siguen siendo validos sh/register y sh/registered, pero se rechazan show/reg,
sh/reg y show/registere. Las demas abreviaturas de comandos DXSpider mantienen su
comportamiento original.

Las acciones de registro de DXWeb y DXWeb Admin utilizan el protocolo reg_*
de Web.pm y llaman directamente a las API de DXReg, no a las cinco rutas de
comandos de consola. Los nombres de mensajes del protocolo no han cambiado.
Esto es una conclusion de compatibilidad del codigo fuente, no sustituye una
prueba integral en un nodo en funcionamiento.


3.1 request/register
--------------------

Usuario normal:

  request/register <email> <language> [ssid-list]

El indicativo (CALL) siempre se obtiene de la sesion conectada.

SYSOP:

  request/register <call> <email> <language> [ssid-list]


Ejemplos:

  request/register user@example.net ES
  request/register user@example.net EN 1,2,5
  request/register EA3XYZ user@example.net ES 1-5

Solo se permite una solicitud PENDING por CALL.
Los registros anteriores con estado ACCEPTED, REJECTED o REMOVED permanecen
en el historial.

Los SSID validos son 1..99. Se rechazan el SSID 0 y las formas con ceros a la
izquierda, como 01..09.

El idioma se guarda como un codigo de dos letras mayusculas.
El formulario de registro web ofrece un selector de idioma y usa EN de
forma predeterminada.
Para buscar plantillas de notificacion se intenta primero el idioma elegido;
si no esta instalada la plantilla correspondiente, DXReg utiliza
automaticamente la plantilla inglesa (.EN) equivalente.

3.2 show/register
-----------------

  show/register
  show/register <call>
  show/register <request-id>

Sin argumentos, muestra las solicitudes PENDING.

Con un CALL, muestra el historial completo de registro de ese indicativo.
Con un ID, muestra esa solicitud con el mismo formato legible del historial.

3.3 accept/register
-------------------

  accept/register <request-id|call> [note]

La forma con CALL resuelve la unica solicitud PENDING de ese indicativo.

La aceptacion:

- conserva los SSID ya registrados;
- anade los SSID nuevos solicitados;
- nunca interpreta la omision de SSID como una eliminacion;
- reutiliza la contrasena del indicativo base si ya existe;
- de lo contrario, genera una nueva contrasena;
- sincroniza la misma contrasena entre el indicativo base y todos los SSID
  aceptados/actuales;
- almacena requested_ssids y accepted_ssids por separado en el historial;
- nunca almacena la contrasena en registration.json ni en los logs de debug.

3.4 reject/register
-------------------

  reject/register <request-id|call> [note]

Marca la solicitud PENDING como REJECTED y, opcionalmente, guarda una nota
administrativa.
Una solicitud posterior del mismo CALL crea un nuevo registro historico.

3.5 remove/register
-------------------

  remove/register <call> [note]

Actua sobre el indicativo base y cada registro DXUser existente CALL-1 ..
CALL-99:

- conserva los registros DXUser;
- establece registered=0;
- elimina la contrasena;
- crea un registro historico REMOVED con los SSID afectados;
- desconecta las sesiones conectadas afectadas despues de persistir los
  cambios, para que el siguiente acceso cargue el nuevo estado.

Un fallo al desconectar se registra en el log, pero no revierte una baja de
registro que ya se haya persistido.

4. Persistencia
---------------

El historial del flujo de solicitudes de registro se almacena en:

  /spider/local_data/registration.json

El estado efectivo de registro y contrasena permanece en DXUser.

El archivo JSON almacena solo el historial administrativo, incluidos:

- ID
- CALL
- email
- idioma
- SSID solicitados
- SSID aceptados/afectados
- estado
- origen
- IP
- marcas de tiempo
- processed_by
- nota opcional

Las contrasenas nunca se almacenan en el archivo JSON.

5. Notificaciones
-----------------

Las notificaciones son opcionales.

Nueva solicitud de registro:

- correo electronico opcional al SYSOP
- mensaje opcional de Telegram al SYSOP

Aceptacion/rechazo:

- correo electronico opcional al usuario

El correo electronico y Telegram no bloquean el bucle principal de DXSpider:

- SMTP se ejecuta en Mojo::IOLoop::Subprocess
- Telegram utiliza Mojo::UserAgent de forma asincrona

Los logs registran estados de notificacion como:

  queued
  sent
  failed

sin registrar contrasenas, credenciales SMTP ni tokens de Telegram.

Las plantillas son UTF-8. Los cuerpos de correo usan MIME UTF-8/Base64 y
Telegram admite formato HTML en sus plantillas.

6. Dependencias
---------------

  - Net::SMTP
  - Net::SMTP::SSL
  - Authen::SASL
  - IO::Socket::SSL
  - Mojo::UserAgent
  - certificados CA habituales

Telegram no requiere curl.

7. Notas
--------

show/register, accept/register, reject/register y remove/register son
operaciones de SYSOP.
request/register esta disponible tanto para usuarios normales como para SYSOP.

Las operaciones de registro son locales al nodo donde se ejecutan.
En V2 no existe propagacion automatica entre nodos.

7.1 Extension de integracion web (DXReg 1.2, 24-Sep-2026)

El mecanismo de registro esta completamente integrado en DXSpider Web Admin.
El SYSOP puede gestionar el flujo de registro directamente desde la interfaz
web, incluida la visualizacion y busqueda de solicitudes y su historial, asi
como la aceptacion, el rechazo o la eliminacion de registros.

Las solicitudes de registro web tambien pueden guardar un nombre opcional
(maximo 80 caracteres) y un comentario del solicitante (maximo 500
caracteres). El campo note existente sigue siendo la nota del SYSOP al
procesar la solicitud.

list_history() y search_history() proporcionan API nativas de lectura para
administracion. Las busquedas por CALL y CALL-SSID se agrupan por indicativo
base y se ordenan de mas recientes a mas antiguas. El codigo web debe usar
estas API y no debe acceder directamente a registration.json.

EOF
