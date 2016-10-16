/**
 * @file main.c
 *
 * @section License
 * Copyright (C) 2016, Erik Moqvist
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * This file is part of the Simba project.
 */

#include "simba.h"

static struct http_server_t server;
static struct shell_t shell;

THRD_STACK(listener_stack, 1024);
THRD_STACK(connection_stack, 1500);

static int request_index(struct http_server_connection_t *connection_p,
                         struct http_server_request_t *request_p);

static struct http_server_route_t routes[] = {
    { .path_p = "/index.html", .callback = request_index },
    { .path_p = NULL, .callback = NULL }
};

static struct http_server_listener_t listener = {
    .address_p = "192.168.0.5",
    .port = 8000,
    .thrd = {
        .name_p = "http_listener",
        .stack = {
            .buf_p = listener_stack,
            .size = sizeof(listener_stack)
        }
    }
};

static struct http_server_connection_t connections[] = {
    {
        .thrd = {
            .name_p = "http_conn_0",
            .stack = {
                .buf_p = connection_stack,
                .size = sizeof(connection_stack)
            }
        }
    },

    { .thrd = { .name_p = NULL } }
};

/**
 * Handler for the index request.
 */
static int request_index(struct http_server_connection_t *connection_p,
                         struct http_server_request_t *request_p)
{
    static const char index_html[] =
        "<!DOCTYPE HTML>\n"
        "<html>\n"
        "  <body>\n"
        "    Hello from Simba!"
        "  </body>\n"
        "</html>\n";
    struct http_server_response_t response;

    /* Only the GET action is supported. */
    if (request_p->action != http_server_request_action_get_t) {
        return (-1);
    }

    /* Create the response. */
    response.code = http_server_response_code_200_ok_t;
    response.content.type = http_server_content_type_text_html_t;
    response.content.buf_p = index_html;
    response.content.size =
        strlen(response.content.buf_p);

    return (http_server_response_write(connection_p,
                                       request_p,
                                       &response));
}

/**
 * Default page handler.
 */
static int no_route(struct http_server_connection_t *connection_p,
                    struct http_server_request_t *request_p)
{
    struct http_server_response_t response;

    /* Create the response. */
    response.code = http_server_response_code_404_not_found_t;
    response.content.type = http_server_content_type_text_html_t;
    response.content.buf_p = NULL;
    response.content.size = 0;

    return (http_server_response_write(connection_p,
                                       request_p,
                                       &response));
}

#if defined(ARCH_ESP)

static int init()
{
    sys_start();

    http_server_init(&server,
                     &listener,
                     connections,
                     NULL,
                     routes,
                     no_route);

    http_server_start(&server);

    return (0);
}

#else

static struct uart_driver_t ipuart;
static char iprxbuf[512];
static struct network_interface_slip_t slip;
static THRD_STACK(stack, 1024);

static void *slip_reader(void *arg_p)
{
    uint8_t data;

    while (1) {
        uart_read(&ipuart, &data, 1);
        network_interface_slip_input(&slip, data);
    }

    return (NULL);
}

static int init()
{
    struct inet_ip_addr_t ipaddr;
    struct inet_ip_addr_t netmask;
    struct inet_ip_addr_t gw;

    sys_start();

    std_printf(sys_get_info());

    uart_init(&ipuart, &uart_device[1], 115200, iprxbuf, sizeof(iprxbuf));
    uart_start(&ipuart);

    inet_module_init();
    socket_module_init();
    network_interface_slip_module_init();

    inet_aton("169.254.1.2", &ipaddr);
    inet_aton("255.255.255.0", &netmask);
    inet_aton("0.0.0.0", &gw);

    network_interface_slip_init(&slip,
                                &ipaddr,
                                &netmask,
                                &gw,
                                &ipuart.chout);
    network_interface_add(&slip.network_interface);
    network_interface_enable(&slip.network_interface);

    thrd_spawn(slip_reader,
               NULL,
               0,
               stack,
               sizeof(stack));

    http_server_init(&server,
                     &listener,
                     connections,
                     NULL,
                     routes,
                     no_route);

    http_server_start(&server);

    return (0);
}

#endif

int main()
{
    init();

    shell_init(&shell,
               sys_get_stdin(),
               sys_get_stdout(),
               NULL,
               NULL,
               NULL,
               NULL);
    shell_main(&shell);

    return (0);
}
