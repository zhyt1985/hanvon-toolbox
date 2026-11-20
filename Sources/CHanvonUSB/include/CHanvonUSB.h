#ifndef CHANVONUSB_H
#define CHANVONUSB_H

#include <stdint.h>
#include <stddef.h>

typedef struct hanvon_usb hanvon_usb;

enum {
    HANVON_USB_NO_DEVICE = -2000,
    HANVON_USB_MULTIPLE_DEVICES = -2001,
    HANVON_USB_NO_MTP = -2002
};

int hanvon_usb_open(hanvon_usb **connection);
void hanvon_usb_close(hanvon_usb *connection);
int hanvon_usb_serial(hanvon_usb *connection, char *buffer, size_t capacity);
int hanvon_usb_speed(hanvon_usb *connection);
int hanvon_usb_out_packet_size(hanvon_usb *connection);
int hanvon_usb_read(hanvon_usb *connection, uint8_t *buffer, int length, int *transferred);
int hanvon_usb_write(hanvon_usb *connection, const uint8_t *buffer, int length, int *transferred);
const char *hanvon_usb_error(int code);

#endif
