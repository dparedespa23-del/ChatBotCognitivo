# Desplegar Chatbot Cognitivo en Dokploy

La opción es **Compose**, tipo **Docker Compose**, con el archivo `docker-compose.yml` de la raíz. No selecciones Stack: este proyecto construye imágenes desde el repositorio.

## 1. Preparar las variables

Desde la raíz del proyecto, en tu computadora:

```powershell
py preparar_despliegue.py
```

Esto crea `.env` con una clave Django y una contraseña administrativa aleatorias. Si ya existe, lo conserva sin cambiar claves. Abre el archivo y copia sus variables en **Environment** de Dokploy. No lo subas al repositorio ni lo pegues en un chat público.

El usuario inicial es `admin`; la contraseña está en `DJANGO_ADMIN_PASSWORD`. La plantilla exige una contraseña propia. Al reiniciar no se restablecen las contraseñas de cuentas existentes. Para cambiar una contraseña posteriormente utiliza la terminal del backend: `python /app/manage.py changepassword admin`.

Para este despliegue, el propietario eligió explícitamente conservar `admin/admin`, igual que en local. Esa excepción requiere `DJANGO_ADMIN_USERNAME=admin`, `DJANGO_ADMIN_PASSWORD=admin` y `DJANGO_ALLOW_INSECURE_ADMIN=true` en las variables privadas. El valor predeterminado de la excepción es `false`; no permite otras contraseñas débiles ni modifica cuentas existentes. Esta credencial es fácil de adivinar y permite acceder a los reportes a quien la conozca.

`.env.example` es una plantilla pública sin credenciales. No debe utilizarse sin completar las claves. Django detiene el arranque si falta una clave secreta válida; la primera creación del administrador también requiere una contraseña válida.

## 2. Crear el servicio

1. Sube al repositorio todos los archivos del proyecto, incluidos los Dockerfile, `docker-compose.yml` y las migraciones. Excluye `.env`, las bases locales y las dependencias.
2. En Dokploy, selecciona **Create Service → Compose** y ponle `chatcognitivo`.
3. Selecciona el proveedor Git y el repositorio/rama que vayas a publicar.
4. En **Compose Path**, selecciona `docker-compose.yml` desde la raíz del repositorio.
5. Conserva el tipo **Docker Compose**.
6. En **Environment**, pega el contenido de tu `.env`.
7. Revisa **Advanced → Networks** y **Preview Compose**. Todos los servicios deben conservar la red privada `aplicacion` del archivo Compose; solo `frontend` necesita además la red del proxy de Dokploy. En Dokploy 0.30.8 la opción antigua **Isolated Deployment** aparece como obsoleta: utiliza la configuración declarativa de Networks si necesitas ajustar las conexiones y comprueba el resultado antes de desplegar. No añadas etiquetas Traefik manuales si utilizas Domains.

## 3. Conectar el dominio

En el proveedor donde administras `chatcognitivo.tech`, configura un registro **A** de `@` hacia la IP pública del servidor. Si tienes un registro AAAA antiguo, debe apuntar al servidor correcto o retirarse. Para `www`, configura también su DNS si vas a utilizarlo.

En la pestaña **Domains** de este Compose añade:

| Opción | Valor |
| --- | --- |
| Host | `chatcognitivo.tech` |
| Path | `/` |
| Service | `frontend` |
| Container Port | `80` |
| HTTPS | Activado |
| Certificate | Let's Encrypt |

Puedes añadir `www.chatcognitivo.tech` al mismo servicio y puerto cuando su DNS esté configurado. La dirección principal sigue siendo `https://chatcognitivo.tech`.

En la instancia publicada están configurados ambos dominios con HTTPS. El sistema administrativo de la aplicación está en `https://chatcognitivo.tech/administrador`. `https://admin.chatcognitivo.tech` corresponde exclusivamente al panel de Dokploy y conserva su propio acceso.

El dominio debe apuntar al **frontend**, que atiende React y envía `/api/` al backend. No crees un dominio público para Ollama, el worker o el backend. No publiques el puerto 11434.

Guarda los cambios y utiliza **Preview Compose** para revisar la configuración final. Después pulsa **Deploy**. Cambiar dominios de un Compose requiere un nuevo despliegue.

## 4. Qué inicia automáticamente

| Servicio | Trabajo |
| --- | --- |
| `ollama` | Ejecuta el modelo en una red privada cuando `COMPOSE_PROFILES=ollama`. |
| `modelo` | Espera a Ollama y descarga `deepseek-r1:8b` si todavía falta. Termina con código 0 al completarse; es normal que figure como finalizado. |
| `backend` | Aplica migraciones, prepara el administrador según las variables privadas, recopila estáticos y arranca Gunicorn. |
| `worker` | Analiza mensajes y revisa cierres semanales cada 15 segundos, después de que el backend esté listo. |
| `frontend` | Sirve la compilación React mediante Nginx y dirige `/api/` a Django. |

La primera descarga del modelo puede tardar y requiere espacio de disco y memoria suficientes para ejecutarlo. Mientras se prepara el modelo, los servicios dependientes pueden aparecer esperando. Consulta los registros de `modelo` y `ollama`.

El servidor usa CPU por defecto (`OLLAMA_NUM_GPU=0`). El tiempo de respuesta depende de sus recursos; no se garantiza la velocidad observada en tu computadora. El modelo descargado en tu PC no se transfiere con Git.

## 5. Comprobar el despliegue

Abre estas direcciones después del despliegue:

- `https://chatcognitivo.tech/api/salud/`: debe devolver `{"estado":"ok"}`.
- `https://chatcognitivo.tech/registro`: crear cuenta de estudiante.
- `https://chatcognitivo.tech/chat`: conversar y comprobar una respuesta.
- `https://chatcognitivo.tech/administrador`: acceder con las credenciales de `.env`.

Recargar directamente `/chat` o `/administrador` debe mantener la pantalla gracias a la configuración de Nginx. El inicio de sesión utiliza cookies seguras y CSRF bajo el mismo dominio. No necesitas configurar CORS.

En la terminal de **backend** puedes ejecutar:

```sh
python /app/manage.py check --deploy
```

Revisa también que `worker` permanezca ejecutándose. Los reportes necesitan ese proceso incluso cuando nadie visita el chat. La generación del reporte puede seguir pendiente mientras se analizan mensajes.

La comprobación del despliegue inicial incluyó registro con una cuenta ficticia, dos respuestas reales del modelo, acceso administrativo y salud bajo HTTPS en ambos dominios. El VPS ejecuta DeepSeek en CPU: las dos respuestas de esta prueba tardaron aproximadamente 64 y 110 segundos. Son tiempos observados, no una garantía; el análisis de indicadores también se procesa en segundo plano. El primer reporte semanal se conserva al terminar los siete días de la cuenta, no inmediatamente después del registro.

La optimización posterior entrega las respuestas por partes, reduce instrucciones e historial enviado al modelo y limita las respuestas directas a 192 tokens. También precalienta el modelo al iniciar el backend y lo mantiene cargado mediante `OLLAMA_KEEP_ALIVE=-1`. Estas mejoras se aplican al actualizar el repositorio y reconstruir los servicios: no requieren cambiar claves ni tablas. El tope de 192 también se aplica cuando Environment conserva `OLLAMA_CHAT_MAX_TOKENS=512`. Los tiempos del párrafo anterior corresponden a la versión inicial, que esperaba la respuesta completa.

El Compose permite dos espacios de contexto (`OLLAMA_NUM_PARALLEL=2`) y activa `OLLAMA_MULTIUSER_CACHE=true`. Ollama puede conservar y reutilizar prefijos de solicitudes distintas al alternar entre chat y análisis; el worker mantiene su cancelación y prioridad a favor del chat. Esto utiliza más memoria de contexto, sin duplicar los pesos del modelo. Para un servidor con menos memoria se puede volver a un espacio con `OLLAMA_NUM_PARALLEL=1`. La caché no garantiza una respuesta instantánea: un contexto nuevo todavía requiere cálculo y las solicitudes simultáneas comparten CPU.

La base del servidor comienza vacía: no se copian usuarios ni mensajes de la base de tu computadora. El aviso de correo SMTP en la configuración no implementa envío de reportes: esa función todavía no existe.

## 6. Datos persistentes y actualizaciones

Se conservan tres volúmenes Docker:

| Volumen | Contenido |
| --- | --- |
| `datos` | SQLite en `/data/db.sqlite3`: usuarios, mensajes, semanas, evidencias y reportes. |
| `modelos` | Modelos descargados de Ollama. |
| `estaticos` | Archivos estáticos de Django, compartidos con Nginx. |

Las rutas se guardan en volúmenes, no dentro del repositorio que Dokploy vuelve a clonar. Conserva el mismo servicio/proyecto y sus volúmenes al actualizar. No uses opciones para eliminar o recrear volúmenes si deseas conservar los datos. Configura respaldos del volumen `datos` desde Dokploy.

Se conserva SQLite, igual que en desarrollo. Gunicorn utiliza un proceso y cuatro hilos; el worker comparte la misma base. Este despliegue está previsto para una sola instancia del backend y un worker. Antes de escalar a varias réplicas conviene preparar una migración a PostgreSQL y revisar los límites de conexión al modelo.

Para generar una copia consistente, en la terminal del backend:

```sh
python -c "import sqlite3; origen=sqlite3.connect('/data/db.sqlite3'); destino=sqlite3.connect('/data/respaldo.sqlite3'); origen.backup(destino); destino.close(); origen.close()"
```

Descarga después `/data/respaldo.sqlite3` mediante las herramientas del servidor. No sustituyas la base mientras los procesos estén escribiendo.

## 7. Usar Ollama externo

Si ya tienes Ollama en otro servidor accesible de forma privada, cambia en **Environment**:

```dotenv
COMPOSE_PROFILES=
OLLAMA_URL=http://DIRECCION-PRIVADA:11434
```

El perfil vacío omite el contenedor `ollama`. El servicio `modelo` comprobará el modelo en ese servidor y solo lo descargará si falta. El backend y el worker utilizarán esa misma URL.

La dirección debe ser accesible desde los contenedores. `127.0.0.1` apunta al propio contenedor. El Ollama de tu computadora solo sirve para producción si existe una conexión privada disponible y tu equipo permanece encendido. No abras su API directamente a Internet.

## 8. NVIDIA opcional

Si tu servidor tiene GPU NVIDIA y NVIDIA Container Toolkit, utiliza también `docker-compose.gpu.yml` y cambia `OLLAMA_NUM_GPU=16` en Environment. El comando equivalente de Docker Compose es:

```sh
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

Si lo configuras mediante el comando personalizado de Dokploy, conserva el nombre de proyecto y las demás opciones que Dokploy muestra e incorpora ambos argumentos `-f`. No actives esta opción en un servidor sin GPU compatible. No es necesaria para el despliegue inicial con CPU.

## 9. Archivos de despliegue

- `docker-compose.yml`: servicios, variables, volúmenes y orden de arranque.
- `docker-compose.gpu.yml`: acceso opcional a GPU NVIDIA.
- `backend/Dockerfile`: imagen Python para backend y worker, sin base local ni secretos.
- `backend/requirements-production.txt`: servidor Gunicorn además de Django.
- `backend/docker/entrypoint.sh`: preparación de la base y arranque del servidor.
- `backend/gunicorn.conf.py`: servidor de producción y tiempos de espera.
- `frontend/Dockerfile`: compilación React y servidor Nginx.
- `frontend/nginx.conf`: rutas de React, API, estáticos y protocolo HTTPS del proxy.
- `.env.example`: plantilla de variables sin contraseñas.
- `preparar_despliegue.py`: genera el archivo privado `.env` sin reemplazar uno existente.

Referencias: [Compose en Dokploy](https://docs.dokploy.com/docs/core/docker-compose), [dominios](https://docs.dokploy.com/docs/core/docker-compose/domains), [redes aisladas](https://docs.dokploy.com/docs/core/docker-compose/utilities) y [Ollama en Docker](https://docs.ollama.com/docker).
