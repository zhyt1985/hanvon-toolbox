#include "CHanvonUSB.h"
#include <libusb.h>
#include <stdlib.h>
#include <string.h>

struct hanvon_usb {
    libusb_context *context;
    libusb_device_handle *device;
    int interface_number;
    uint8_t input_endpoint;
    uint8_t output_endpoint;
    uint16_t output_packet_size;
    uint8_t serial_index;
    int speed;
};

static int find_mtp_interface(libusb_device *device, struct hanvon_usb *connection) {
    struct libusb_config_descriptor *config = NULL;
    int result = libusb_get_active_config_descriptor(device, &config);
    if (result < 0) return result;

    result = HANVON_USB_NO_MTP;
    for (int index = 0; index < config->bNumInterfaces; index++) {
        const struct libusb_interface *interface = &config->interface[index];
        for (int alt_index = 0; alt_index < interface->num_altsetting; alt_index++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[alt_index];
            if (alt->bAlternateSetting != 0 || alt->bInterfaceClass != 6 ||
                alt->bInterfaceSubClass != 1 || alt->bInterfaceProtocol != 1) continue;

            uint8_t incoming = 0, outgoing = 0;
            uint16_t packet_size = 0;
            for (int endpoint_index = 0; endpoint_index < alt->bNumEndpoints; endpoint_index++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpoint_index];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
                if (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) {
                    incoming = endpoint->bEndpointAddress;
                } else {
                    outgoing = endpoint->bEndpointAddress;
                    packet_size = endpoint->wMaxPacketSize;
                }
            }
            if (!incoming || !outgoing || !packet_size) continue;
            connection->interface_number = alt->bInterfaceNumber;
            connection->input_endpoint = incoming;
            connection->output_endpoint = outgoing;
            connection->output_packet_size = packet_size;
            result = 0;
            goto done;
        }
    }
done:
    libusb_free_config_descriptor(config);
    return result;
}

int hanvon_usb_open(hanvon_usb **output) {
    *output = NULL;
    hanvon_usb *connection = calloc(1, sizeof(*connection));
    if (!connection) return LIBUSB_ERROR_NO_MEM;
    int result = libusb_init(&connection->context);
    if (result < 0) {
        free(connection);
        return result;
    }

    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(connection->context, &list);
    if (count < 0) {
        result = (int)count;
        goto fail;
    }

    libusb_device *selected = NULL;
    struct libusb_device_descriptor descriptor;
    for (ssize_t index = 0; index < count; index++) {
        struct libusb_device_descriptor candidate;
        if (libusb_get_device_descriptor(list[index], &candidate) < 0) continue;
        if (candidate.idVendor != 0x2207 || candidate.idProduct != 0x0007) continue;
        if (selected) {
            result = HANVON_USB_MULTIPLE_DEVICES;
            goto free_list;
        }
        selected = list[index];
        descriptor = candidate;
    }
    if (!selected) {
        result = HANVON_USB_NO_DEVICE;
        goto free_list;
    }

    result = find_mtp_interface(selected, connection);
    if (result < 0) goto free_list;
    connection->speed = libusb_get_device_speed(selected);
    connection->serial_index = descriptor.iSerialNumber;

    result = libusb_open(selected, &connection->device);
    if (result < 0) goto free_list;
    unsigned char manufacturer[128] = {0};
    result = libusb_get_string_descriptor_ascii(connection->device, descriptor.iManufacturer,
                                                 manufacturer, sizeof(manufacturer) - 1);
    if (result < 0) goto close_device;
    if (strcasecmp((const char *)manufacturer, "HANVON") != 0) {
        result = HANVON_USB_NO_DEVICE;
        goto close_device;
    }
    result = libusb_claim_interface(connection->device, connection->interface_number);
    if (result < 0) goto close_device;
    libusb_free_device_list(list, 1);
    *output = connection;
    return 0;

close_device:
    libusb_close(connection->device);
free_list:
    libusb_free_device_list(list, 1);
fail:
    libusb_exit(connection->context);
    free(connection);
    return result;
}

void hanvon_usb_close(hanvon_usb *connection) {
    if (!connection) return;
    libusb_release_interface(connection->device, connection->interface_number);
    libusb_close(connection->device);
    libusb_exit(connection->context);
    free(connection);
}

int hanvon_usb_serial(hanvon_usb *connection, char *buffer, size_t capacity) {
    if (!capacity || !connection->serial_index) return LIBUSB_ERROR_NOT_FOUND;
    int length = libusb_get_string_descriptor_ascii(connection->device, connection->serial_index,
                                                     (unsigned char *)buffer, (int)capacity - 1);
    if (length >= 0) buffer[length] = 0;
    return length;
}

int hanvon_usb_speed(hanvon_usb *connection) {
    return connection->speed;
}

int hanvon_usb_out_packet_size(hanvon_usb *connection) {
    return connection->output_packet_size;
}

int hanvon_usb_read(hanvon_usb *connection, uint8_t *buffer, int length, int *transferred) {
    return libusb_bulk_transfer(connection->device, connection->input_endpoint,
                                buffer, length, transferred, 5000);
}

int hanvon_usb_write(hanvon_usb *connection, const uint8_t *buffer, int length, int *transferred) {
    return libusb_bulk_transfer(connection->device, connection->output_endpoint,
                                (uint8_t *)buffer, length, transferred, 5000);
}

const char *hanvon_usb_error(int code) {
    return libusb_error_name(code);
}
