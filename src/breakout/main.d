/*
 *             Copyright Andrej Mitrovic 2013.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module breakout.main;

import core.memory;

import core.stdc.stdio;
import core.stdc.stdlib;

import std.exception;
import std.random;
import std.stdio;
import std.string;

alias stderr = std.stdio.stderr;

import glad.gl.all;
import glad.gl.loader;

import deimos.glfw.glfw3;

import dchip.all;

import breakout.draw;
import breakout.glu;
import breakout.physics;
import breakout.text;
import breakout.types;
import breakout.util;

alias ChipmunkDemoInitFunc = cpSpace* function();
alias ChipmunkDemoUpdateFunc = void function(cpSpace* space, double dt);
alias ChipmunkDemoDrawFunc = void function(cpSpace* space);
alias ChipmunkDemoDestroyFunc = void function(cpSpace* space);

__gshared GLFWwindow* window;

struct ChipmunkDemo
{
    string name;
    double timestep;

    ChipmunkDemoInitFunc initFunc;
    ChipmunkDemoUpdateFunc updateFunc;
    ChipmunkDemoDrawFunc drawFunc;
    ChipmunkDemoDestroyFunc destroyFunc;
}

cpFloat frand()
{
    return cast(cpFloat)rand() / cast(cpFloat)RAND_MAX;
}

cpVect frand_unit_circle()
{
    cpVect v = cpv(frand() * 2.0f - 1.0f, frand() * 2.0f - 1.0f);
    return (cpvlengthsq(v) < 1.0f ? v : frand_unit_circle());
}

cpBool paused = cpFalse;
cpBool step   = cpFalse;

double Accumulator = 0.0;
double LastTime    = 0.0;
int ChipmunkDemoTicks = 0;
double ChipmunkDemoTime;

cpVect ChipmunkDemoMouse;
cpBool ChipmunkDemoRightClick = cpFalse;
cpBool ChipmunkDemoRightDown  = cpFalse;
cpVect ChipmunkDemoKeyboard;

cpBody* mouse_body        = null;
cpConstraint* mouse_joint = null;

cpVect  translate = { 0, 0 };
cpFloat scale = 1.0;

void ShapeFreeWrap(cpSpace* space, cpShape* shape, void* unused)
{
    cpSpaceRemoveShape(space, shape);
    cpShapeFree(shape);
}

void PostShapeFree(cpShape* shape, cpSpace* space)
{
    cpSpaceAddPostStepCallback(space, safeCast!cpPostStepFunc(&ShapeFreeWrap), shape, null);
}

void ConstraintFreeWrap(cpSpace* space, cpConstraint* constraint, void* unused)
{
    cpSpaceRemoveConstraint(space, constraint);
    cpConstraintFree(constraint);
}

void PostConstraintFree(cpConstraint* constraint, cpSpace* space)
{
    cpSpaceAddPostStepCallback(space, safeCast!cpPostStepFunc(&ConstraintFreeWrap), constraint, null);
}

void BodyFreeWrap(cpSpace* space, cpBody* body_, void* unused)
{
    cpSpaceRemoveBody(space, body_);
    cpBodyFree(body_);
}

void PostBodyFree(cpBody* body_, cpSpace* space)
{
    cpSpaceAddPostStepCallback(space, safeCast!cpPostStepFunc(&BodyFreeWrap), body_, null);
}

// Safe and future proof way to remove and free all objects that have been added to the space.
void ChipmunkDemoFreeSpaceChildren(cpSpace* space)
{
    // Must remove these BEFORE freeing the body_ or you will access dangling pointers.
    cpSpaceEachShape(space, safeCast!cpSpaceShapeIteratorFunc(&PostShapeFree), space);
    cpSpaceEachConstraint(space, safeCast!cpSpaceConstraintIteratorFunc(&PostConstraintFree), space);

    cpSpaceEachBody(space, safeCast!cpSpaceBodyIteratorFunc(&PostBodyFree), space);
}

int max_arbiters    = 0;
int max_points      = 0;
int max_constraints = 0;

void Tick(double dt)
{
    if (!paused || step)
    {
        // Completely reset the renderer only at the beginning of a tick.
        // That way it can always display at least the last ticks' debug drawing.
        ChipmunkDebugDrawClearRenderer();

        cpVect new_point = cpvlerp(mouse_body.p, ChipmunkDemoMouse, 0.25f);
        mouse_body.v = cpvmult(cpvsub(new_point, mouse_body.p), 60.0f);
        mouse_body.p = new_point;

        physics.updateFunc(space, dt);

        ChipmunkDemoTicks++;
        ChipmunkDemoTime += dt;

        step = cpFalse;
        ChipmunkDemoRightDown = cpFalse;
    }
}

void Update()
{
    double time = glfwGetTime();
    double dt   = time - LastTime;

    // don't enter an infinite physics loop when we end up lagging behind.
    // todo: this shouldn't be hardcoded to 200 msecs, we should use ticksPerSec to calculate this.
    if (dt > 0.2)
        dt = 0.2;

    double fixed_dt = physics.timestep;

    for (Accumulator += dt; Accumulator > fixed_dt; Accumulator -= fixed_dt)
    {
        Tick(fixed_dt);
    }

    LastTime = time;
}

void Display()
{
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glTranslatef(cast(GLfloat)translate.x, cast(GLfloat)translate.y, 0.0f);
    glScalef(cast(GLfloat)scale, cast(GLfloat)scale, 1.0f);

    Update();

    ChipmunkDebugDrawPushRenderer();
    physics.drawFunc(space);

    // Highlight the shape under the mouse because it looks neat.
    cpShape* nearest = cpSpaceNearestPointQueryNearest(space, ChipmunkDemoMouse, 0.0f, Layers.all_objects, CP_NO_GROUP, null);

    if (nearest)
        ChipmunkDebugDrawShape(nearest, RGBAColor(1.0f, 0.0f, 0.0f, 1.0f), LAColor(0.0f, 0.0f));

    // Draw the renderer contents and reset it back to the last tick's state.
    ChipmunkDebugDrawFlushRenderer();
    ChipmunkDebugDrawPopRenderer();

    ChipmunkDemoTextPushRenderer();

    // Now render all the UI text.
    drawText();

    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    {
        // Draw the text at fixed positions,
        // but save the drawing matrix for the mouse picking
        glLoadIdentity();

        ChipmunkDemoTextFlushRenderer();
        ChipmunkDemoTextPopRenderer();
    }
    glPopMatrix();

    glfwSwapBuffers(window);
    glClear(GL_COLOR_BUFFER_BIT);
}

int curWindowWidth = 640;
int curWindowHeight = 480;

extern(C) void Reshape(GLFWwindow* window, int width, int height)
{
    curWindowWidth = width;
    curWindowHeight = curWindowHeight;
    glViewport(0, 0, width, height);

    float scale = cast(float)cpfmin(width / 640.0, height / 480.0);
    float hw    = width * (0.5f / scale);
    float hh    = height * (0.5f / scale);

    ChipmunkDebugDrawPointLineScale = scale;
    glLineWidth(cast(GLfloat)scale);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluOrtho2D(-hw, hw, -hh, hh);
}

char[] demoTitle()
{
    static char[1024] title;
    title[] = 0;
    title[0 .. physics.name.length] = physics.name[];
    return title;
}

void runGame()
{
    srand(45073);

    ChipmunkDemoTicks = 0;
    ChipmunkDemoTime  = 0.0;
    Accumulator       = 0.0;
    LastTime = glfwGetTime();

    mouse_joint = null;
    max_arbiters    = 0;
    max_points      = 0;
    max_constraints = 0;
    space = physics.initFunc();

    enforce(window !is null);
    glfwSetWindowTitle(window, demoTitle().toStringz);
}

char[1024] textToDraw;
size_t textLength;

void drawText()
{
    if (textToDraw.length)
    {
        ChipmunkDemoTextDrawString(cpv(-250, 200), textToDraw[0 .. textLength]);
    }
}

void updateText()
{
    textLength = sformat(textToDraw, "maxDist: %s - gravity: %s", maxDist, gravity).length;
}

extern(C) void Keyboard(GLFWwindow* window, int key, int scancode, int state, int modifier)
{
    if (state != GLFW_REPEAT)  // we ignore repeat
    switch (key)
    {
        case GLFW_KEY_UP:
            ChipmunkDemoKeyboard.y += (state == GLFW_PRESS ?  1.0 : -1.0);
            break;

        case GLFW_KEY_DOWN:
            ChipmunkDemoKeyboard.y += (state == GLFW_PRESS ? -1.0 :  1.0);
            break;

        case GLFW_KEY_RIGHT:
            ChipmunkDemoKeyboard.x += (state == GLFW_PRESS ?  1.0 : -1.0);
            break;

        case GLFW_KEY_LEFT:
            ChipmunkDemoKeyboard.x += (state == GLFW_PRESS ? -1.0 :  1.0);
            break;

        default:
            break;
    }

    if (state != GLFW_RELEASE)
    switch (key)
    {
        case GLFW_KEY_LEFT_CONTROL:
            fireBullets(PassThrough.no);
            break;

        case GLFW_KEY_A:
            maxDist *= 2;
            updateText();
            break;

        case GLFW_KEY_D:
            maxDist /= 2;
            updateText();
            break;

        case GLFW_KEY_Q:
            gravity *= 2;
            updateText();
            break;

        case GLFW_KEY_E:
            gravity /= 2;
            updateText();
            break;

        default:
            break;
    }

    if (key == GLFW_KEY_ESCAPE && (state == GLFW_PRESS || state == GLFW_REPEAT))
        glfwSetWindowShouldClose(window, true);

    // We ignore release for these next keys.
    if (state == GLFW_RELEASE)
        return;

    if (key == ' ')
    {
        physics.destroyFunc(space);
        runGame();
    }
    else if (key == '`')
    {
        paused = !paused;
    }
    else if (key == '1')
    {
        step = cpTrue;
    }
    else if (key == '\\')
    {
        glDisable(GL_LINE_SMOOTH);
        glDisable(GL_POINT_SMOOTH);
    }

    GLfloat translate_increment = 50.0f / cast(GLfloat)scale;
    GLfloat scale_increment     = 1.2f;

    if (key == '5')
    {
        translate.x = 0.0f;
        translate.y = 0.0f;
        scale       = 1.0f;
    }
    else if (key == '4')
    {
        translate.x += translate_increment;
    }
    else if (key == '6')
    {
        translate.x -= translate_increment;
    }
    else if (key == '2')
    {
        translate.y += translate_increment;
    }
    else if (key == '8')
    {
        translate.y -= translate_increment;
    }
    else if (key == '7')
    {
        scale /= scale_increment;
    }
    else if (key == '9')
    {
        scale *= scale_increment;
    }
}

cpVect MouseToSpace(double x, double y)
{
    GLdouble[16] model;
    glGetDoublev(GL_MODELVIEW_MATRIX, model.ptr);

    GLdouble[16] proj;
    glGetDoublev(GL_PROJECTION_MATRIX, proj.ptr);

    GLint[4] view;
    glGetIntegerv(GL_VIEWPORT, view.ptr);

    int ww, wh;
    glfwGetWindowSize(window, &ww, &wh);

    GLdouble mx, my, mz;
    gluUnProject(x, wh - y, 0.0f, model.ptr, proj.ptr, view.ptr, &mx, &my, &mz);

    return cpv(mx, my);
}

extern(C) void Mouse(GLFWwindow* window, double x, double y)
{
    ChipmunkDemoMouse = MouseToSpace(x, y);
}

extern(C) void Click(GLFWwindow* window, int button, int state, int mods)
{
    if (button == GLFW_MOUSE_BUTTON_1)
    {
        if (state == GLFW_PRESS)
        {
            drawSelector = true;

            cpNearestPointQueryInfo nearestInfo;
            cpSpaceNearestPointQueryNearest(space, ChipmunkDemoMouse, selectorDist, Layers.can_grab, CP_NO_GROUP, &nearestInfo);

            auto shape = nearestInfo.shape;

            if (shape && cpBodyGetMass(cpShapeGetBody(shape)) < INFINITY)
            {
                cpBody *body_ = cpShapeGetBody(shape);
                mouse_joint = cpPivotJointNew2(mouse_body, body_, cpvzero, cpBodyWorld2Local(body_, ChipmunkDemoMouse));
                mouse_joint.maxForce  = 50000.0f;
                mouse_joint.errorBias = cpfpow(1.0f - 0.15f, 60.0f);
                cpSpaceAddConstraint(space, mouse_joint);
            }
        }
        else
        if (state == GLFW_RELEASE && mouse_joint)
        {
            cpSpaceRemoveConstraint(space, mouse_joint);
            cpConstraintFree(mouse_joint);
            mouse_joint = null;
        }

        if (state == GLFW_RELEASE)
        {
            drawSelector = false;
        }
    }
    else
    if (button == GLFW_MOUSE_BUTTON_2)
    {
        if (state == GLFW_PRESS)
            createBall(space, PassThrough.no, HasGravity.no, ChipmunkDemoMouse, cpvzero);

        ChipmunkDemoRightDown = ChipmunkDemoRightClick = (state == GLFW_PRESS);
    }
    else
    if (button == GLFW_MOUSE_BUTTON_3)
    {
        if (state == GLFW_PRESS)
        {
            // find any existing brick within a small region of the mouse, and remove it if it exists.
            cpNearestPointQueryInfo nearestInfo;
            immutable float killDist = 2.0;

            cpSpaceNearestPointQueryNearest(space, ChipmunkDemoMouse, killDist, CP_ALL_LAYERS, CP_NO_GROUP, &nearestInfo);
            auto shape = nearestInfo.shape;

            if (shape && shape.group == Groups.brick)
            {
                if (cpSpaceGetPostStepCallback(space, shape) is null)
                    enforce(cpSpaceAddPostStepCallback(space, &removeBody, shape, null));
            }
            else
            {
                // only spawn a brick if one is not close to it
                bool anyFound = false;
                static void func(cpShape* shape, void* anyFound)
                {
                    *cast(bool*)anyFound = true;
                }

                // attempt to add a new brick if it can fit in this space
                float brickWidth = 40;
                float brickHeight = 20;

                auto xOrigin = ChipmunkDemoMouse.x - (brickWidth / 2.0);
                auto yOrigin = ChipmunkDemoMouse.y - (brickHeight / 2.0);

                // left, bottom, right, top
                // however we have to offset it, since brick creation has a bottom-left origin
                auto bb = cpBB(xOrigin, yOrigin, xOrigin + brickWidth, yOrigin + brickHeight);

                cpSpaceBBQuery(space, bb, CP_ALL_LAYERS, CP_NO_GROUP, &func, &anyFound);

                // todo note: we've temporarily hardcoded it to be explosive for testing.
                if (!anyFound)
                    createBrick(space, ChipmunkDemoMouse, cpVect(brickWidth, brickHeight), BrickKillable.yes, BrickExplosive.yes);
            }
        }
    }
}

extern(C) void WindowClose(GLFWwindow* window)
{
    glfwTerminate();
    glfwSetWindowShouldClose(window, true);
}

void SetupGL()
{
    ChipmunkDebugDrawInit();
    ChipmunkDemoTextInit();

    glClearColor(52.0f / 255.0f, 62.0f / 255.0f, 72.0f / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_LINE_SMOOTH);
    glEnable(GL_POINT_SMOOTH);

    glHint(GL_LINE_SMOOTH_HINT, GL_DONT_CARE);
    glHint(GL_POINT_SMOOTH_HINT, GL_DONT_CARE);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

int main(string[] args)
{
    GC.disable();
    scope (exit)
        GC.enable();

    // Segment/segment collisions need to be explicitly enabled currently.
    // This will becoume enabled by default in future versions of Chipmunk.
    cpEnableSegmentToSegmentCollisions();

    mouse_body = cpBodyNew(INFINITY, INFINITY);

    // initialize glwf
    auto res = glfwInit();
    enforce(res, format("glfwInit call failed with return code: '%s'", res));
    scope(exit)
        glfwTerminate();

    int width = 640;
    int height = 480;

    // Create a windowed mode window and its OpenGL context
    window = enforce(glfwCreateWindow(width, height, "Hello World", null, null),
                          "glfwCreateWindow call failed.");

    // hide mouse cursor
    //~ glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_DISABLED);

    glfwSwapInterval(0);

    // Make the window's context current
    glfwMakeContextCurrent(window);

    // load all glad function pointers
    enforce(gladLoadGL());

    SetupGL();

    glfwSetWindowPos(window, ((1680 - 640) / 2) - 300, ((1050 - 480) / 2) - 150);

    // glfw3 doesn't want to automatically do this the first time the window is shown
    Reshape(window, 640, 480);

    glfwSetWindowSizeCallback(window, &Reshape);
    glfwSetKeyCallback(window, &Keyboard);

    glfwSetCursorPosCallback(window, &Mouse);
    glfwSetMouseButtonCallback(window, &Click);

    updateText();

    runGame();

    /* Loop until the user closes the window */
    while (!glfwWindowShouldClose(window))
    {
        /* Poll for and process events */
        glfwPollEvents();

        /* Render here */
        Display();
    }

    return 0;
}
