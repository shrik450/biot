# Linux host image

Build the image from the repository root:

```sh
docker build -t biot-linux-host docker/linux-host
```

Run host tests with the privileges required by Podman:

```sh
docker run --privileged --rm -it biot-linux-host
```

## Run the suite on Linux

From the repository root, run `docker/linux-host/run-tests.sh`. It copies the repository into the container before running the test suite.
