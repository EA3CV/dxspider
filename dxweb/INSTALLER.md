# DXWeb Installer v0.49 — instalación, actualización y rollback

## Alcance

El gestor `dxweb/dxweb-manager.pl` configura servicios systemd de DXWeb y DXWeb Admin. En modo `direct`, HTTP sirve en 7380 (DXWeb) y 7381 (Admin). El origen es el árbol Git de `/spider`: **el instalador no copia el código de aplicación**. La instalación y el rollback requieren `--apply`; `plan` y el rollback sin `--apply` no alteran servicios.

No se requiere Docker ni Nginx en el despliegue directo. No mezclar este procedimiento con otros proyectos de DXSpider.

## Verificación previa (root, ZSH)

```zsh
cd /spider || exit 1
perl -c dxweb/dxweb-manager.pl
perl dxweb/tests/installer/test_bounded_stop.pl dxweb/dxweb-manager.pl
perl dxweb/tests/installer/test_rollback_state.pl dxweb/dxweb-manager.pl
perl dxweb/dxweb-manager.pl --action plan --root /spider --components both --mode direct --scheme http --user root --group root
```

## Instalar o actualizar

```zsh
cd /spider || exit 1
perl dxweb/dxweb-manager.pl --action install --root /spider --components both --mode direct --scheme http --user root --group root --apply
systemctl show dxweb.service -p ActiveState -p MainPID -p UnitFileState
systemctl show dxweb-admin.service -p ActiveState -p MainPID -p UnitFileState
curl --max-time 5 -sS -o /dev/null -w 'DXWeb: %{http_code}\n' http://127.0.0.1:7380/
curl --max-time 5 -sS -o /dev/null -w 'Admin: %{http_code}\n' http://127.0.0.1:7381/
```

Cada instalación con cambios genera una transacción en `/var/backups/dxweb-installer/`. Conservar su ruta exacta.

## Rollback

Inspeccionar el `manifest.json` de la transacción antes de aplicar. Un rollback de **instalación inicial** puede eliminar la unidad systemd, detener y deshabilitar el servicio; **no** equivale a restaurar una versión anterior del código.

```zsh
cd /spider || exit 1
perl dxweb/dxweb-manager.pl --action rollback --backup /var/backups/dxweb-installer/TRANSACTION
# Solo tras revisar el plan, guardar la unidad actual y confirmar una recuperación:
perl dxweb/dxweb-manager.pl --action rollback --backup /var/backups/dxweb-installer/TRANSACTION --apply
```

No restaurar manualmente la unidad si el rollback falla sin inspeccionar primero la recuperación automática y el checkpoint. El gestor utiliza parada acotada y acepta `LoadState=not-found`, `ActiveState=inactive` como resultado correcto cuando ha retirado intencionadamente una unidad recién creada.

## Evidencia de validación — 27 octubre 2026

- v0.49: sintaxis Perl correcta; pruebas de parada 5/5 y estado de rollback 8/8.
- Instalación/actualización real: `install_rc=0`, transacción `20261027-150415-386862`, ambos HTTP 200.
- Rollback inicial Admin: `rollback_rc=0`, unidad `not-found/inactive`; recuperado, HTTP 200.
- Rollback inicial DXWeb: `rollback_rc=0`, unidad `not-found/inactive`; recuperado, HTTP 200.
- DXSpider siguió en ejecución en las comprobaciones.

Versiones de aplicación observadas: DXWeb 3.0.1 y DXWeb Admin 1.0.3. Esta validación no implica que otros escenarios de instalación, TLS o Nginx hayan sido probados.

## Git y limpieza

Revisar `git status` y `git diff` antes de crear commit. Incorporar solo el instalador, sus pruebas y esta documentación. No eliminar backups, archivos locales no rastreados ni cambios de `badip`, `DXCIDR`, `Web.pm` o `cluster.pl` por pertenecer a trabajos distintos. No ejecutar push sin comprobar el remoto y la rama de destino.
