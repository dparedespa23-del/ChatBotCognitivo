"""Genera las variables privadas de Compose; no cambia cuentas ni publica nada."""
from pathlib import Path
import secrets


def main():
    raiz = Path(__file__).resolve().parent
    destino = raiz / '.env'
    if destino.exists():
        print('Ya existe .env. Se conservaron sus variables y contraseñas.')
        return
    contenido = (raiz / '.env.example').read_text(encoding='utf-8')
    contenido = contenido.replace('DJANGO_SECRET_KEY=\n', f'DJANGO_SECRET_KEY={secrets.token_urlsafe(64)}\n', 1)
    contenido = contenido.replace('DJANGO_ADMIN_PASSWORD=\n', f'DJANGO_ADMIN_PASSWORD={secrets.token_urlsafe(24)}\n', 1)
    with destino.open('x', encoding='utf-8', newline='\n') as archivo:
        archivo.write(contenido)
    print('Archivo .env creado. Copia sus variables en Environment de Dokploy. No lo subas a Git.')
    print('El acceso administrativo usa DJANGO_ADMIN_USERNAME y DJANGO_ADMIN_PASSWORD de ese archivo.')


if __name__ == '__main__':
    main()
