// raylib, rlgl, and the few GLFW calls hull makes itself: raylib's input
// keeps a key and its text apart, so hull takes GLFW's own callbacks.
#include "raylib.h"
#include "rlgl.h"

typedef struct GLFWwindow GLFWwindow;
typedef void (*GLFWkeyfun)(GLFWwindow *window, int key, int scancode, int action, int mods);
typedef void (*GLFWcharfun)(GLFWwindow *window, unsigned int codepoint);
typedef void (*GLFWwindowfocusfun)(GLFWwindow *window, int focused);
GLFWwindow *glfwGetCurrentContext(void);
GLFWkeyfun glfwSetKeyCallback(GLFWwindow *window, GLFWkeyfun callback);
GLFWcharfun glfwSetCharCallback(GLFWwindow *window, GLFWcharfun callback);
GLFWwindowfocusfun glfwSetWindowFocusCallback(GLFWwindow *window, GLFWwindowfocusfun callback);
const char *glfwGetKeyName(int key, int scancode);
void glfwPostEmptyEvent(void);
void glfwWaitEventsTimeout(double timeout);
void glfwPollEvents(void);
void glfwSetWindowShouldClose(GLFWwindow *window, int value);
int glfwWindowShouldClose(GLFWwindow *window);
