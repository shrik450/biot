# Linux host image

Build the image from the repository root:

```sh
docker build -t biot-linux-host docker/linux-host
```

Run host tests with the privileges required by Podman:

```sh
docker run --privileged --rm -it biot-linux-host
```
