#include <xpc/xpc.h>

xpc_connection_t clumsies_xpc_connection_create(const char *service_name) {
    xpc_connection_t connection =
        xpc_connection_create_mach_service(service_name, NULL, 0);
    if (connection == NULL) {
        return NULL;
    }

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
      (void)event;
    });
    xpc_connection_activate(connection);
    return connection;
}
