#include "include/custom_mouse_cursor/custom_mouse_cursor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gdk/gdk.h>
#include <sys/utsname.h>
#include <vector>
#include <string>
#include <unordered_map>

#include <iostream>
#include <cstring>
#include <memory>

using namespace std;

#define CUSTOM_MOUSE_CURSOR_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), custom_mouse_cursor_plugin_get_type(), \
                              CustomMouseCursorPlugin))

struct _CustomMouseCursorPlugin
{
  GObject parent_instance;
  FlPluginRegistrar *registrar;
  unique_ptr<unordered_map<string, GdkCursor*>> cache;
};

G_DEFINE_TYPE(CustomMouseCursorPlugin, custom_mouse_cursor_plugin, g_object_get_type())

// Gets the window being controlled.
GtkWindow *get_window(CustomMouseCursorPlugin *self)
{
  FlView *view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr)
    return nullptr;

  return GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

GdkWindow *get_gdk_window(CustomMouseCursorPlugin *self)
{
  return gtk_widget_get_window(GTK_WIDGET(get_window(self)));
}

// The [args] will contain
//  <String, dynamic>{
//     'name': string,
//     'buffer': ptr to png pixel buffer,
//     'hotX : double - x coord of hotspot
//     'hotY' : double - y coord of hotspor
//     'width':  int - width of image in pixelbuffer
//     'height': int - height of image in pixelbuffer
//   },
/* 
Thisd mimics the flutter's built in handing of custom cursors for windows
from engine/src/flutter/shell/platform/windows/cursor_handler.cc:

static constexpr char kCustomCursorNameKey[] = "name";
// A list of bytes, the custom cursor's rawBGRA buffer.
static constexpr char kCustomCursorBufferKey[] = "buffer";
// A double, the x coordinate of the custom cursor's hotspot, starting from
// left.
static constexpr char kCustomCursorHotXKey[] = "hotX";
// A double, the y coordinate of the custom cursor's hotspot, starting from top.
static constexpr char kCustomCursorHotYKey[] = "hotY";
// An int value for the width of the custom cursor.
static constexpr char kCustomCursorWidthKey[] = "width";
// An int value for the height of the custom cursor.
static constexpr char kCustomCursorHeightKey[] = "height";
*/
static string create_custom_cursor(CustomMouseCursorPlugin *self, FlValue *args)
{
  auto name = string(fl_value_get_string(fl_value_lookup_string(args, "name")));
  double hot_x = fl_value_get_float(fl_value_lookup_string(args, "hotX"));
  double hot_y = fl_value_get_float(fl_value_lookup_string(args, "hotY"));
  // Ignore [width] and [height].
  // int width = fl_value_get_int(fl_value_lookup_string(args, "width"));
  // int height = fl_value_get_int(fl_value_lookup_string(args, "height"));
  GdkPixbuf* pixbuf = nullptr;
  auto buffer = fl_value_lookup_string(args, "buffer");
  const uint8_t *cursor_buff = fl_value_get_uint8_list(buffer);
  auto length = fl_value_get_length(buffer);
  if (cursor_buff == nullptr) {
    return nullptr;
  }
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  gdk_pixbuf_loader_write(loader, cursor_buff, length, nullptr);
  // if (width >= 0 && height >= 0)
  // {
  //   gdk_pixbuf_loader_set_size(loader, width, height);
  // }
  gdk_pixbuf_loader_close(loader, nullptr);
  pixbuf = gdk_pixbuf_copy(gdk_pixbuf_loader_get_pixbuf(loader));
  GdkDisplay *display = gdk_display_get_default();
  GdkCursor* cursor = nullptr;
  cursor = gdk_cursor_new_from_pixbuf(display, pixbuf, hot_x, hot_y);
  if (cursor == nullptr) {
    return nullptr;
  }
  self->cache->insert(std::make_pair(name, cursor));
  return name;
}

static bool set_custom_cursor(CustomMouseCursorPlugin* self, FlValue *args) {
  auto name = string(fl_value_get_string(fl_value_lookup_string(args, "name")));
  if (self->cache->find(name) != self->cache->end()) {
    GtkWindow *window = get_window(self);
    gdk_window_set_cursor(gtk_widget_get_window(GTK_WIDGET(window)), self->cache->at(name));
    return true;
  } else {
    return false;
  }
}

static bool delete_custom_cursor(CustomMouseCursorPlugin* self, FlValue *args) {
  auto name = string(fl_value_get_string(fl_value_lookup_string(args, "name")));
  if (self->cache->find(name) != self->cache->end()) {
    auto cursor = self->cache->at(name);
    g_object_unref(cursor);
    self->cache->erase(name);
    return true;
  }
  return false;
}

// Called when a method call is received from Flutter.
static void custom_mouse_cursor_plugin_handle_method_call(
    CustomMouseCursorPlugin *self,
    FlMethodCall *method_call)
{
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);
  if (strcmp(method, "getPlatformVersion") == 0)
  {
    struct utsname uname_data = {};
    uname(&uname_data);
    g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
    g_autoptr(FlValue) result = fl_value_new_string(version);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  else if (strcmp(method, "createCustomCursor") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    auto ret = create_custom_cursor(self, args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_string(ret.c_str())));
  }
  else if (strcmp(method, "setCustomCursor") == 0)
  {
    auto args = fl_method_call_get_args(method_call); 
    set_custom_cursor(self, args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  else if (strcmp(method, "deleteCustomCursor") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    delete_custom_cursor(self, args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void custom_mouse_cursor_plugin_dispose(GObject *object)
{
  G_OBJECT_CLASS(custom_mouse_cursor_plugin_parent_class)->dispose(object);
}

static void custom_mouse_cursor_plugin_class_init(CustomMouseCursorPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = custom_mouse_cursor_plugin_dispose;
}

static void custom_mouse_cursor_plugin_init(CustomMouseCursorPlugin *self) {
  self->cache = make_unique<unordered_map<string, GdkCursor*>>();
}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  CustomMouseCursorPlugin *plugin = CUSTOM_MOUSE_CURSOR_PLUGIN(user_data);
  custom_mouse_cursor_plugin_handle_method_call(plugin, method_call);
}

void custom_mouse_cursor_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  CustomMouseCursorPlugin *plugin = CUSTOM_MOUSE_CURSOR_PLUGIN(
      g_object_new(custom_mouse_cursor_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "custom_mouse_cursor",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
