/*
 *             Copyright Andrej Mitrovic 2013.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module breakout.types;

import glad.gl.all;

import dchip.all;

/**
    This module contains all the types which the various drawing modules use.
    In the C source the types were duplicated across source files,
    probably to avoid too many #include's.
*/

struct Color
{
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 0;
}

Color RGBAColor(float r, float g, float b, float a)
{
    Color color = { r, g, b, a };
    return color;
}

Color LAColor(float l, float a)
{
    Color color = { l, l, l, a };
    return color;
}

struct v2f
{
    static v2f opCall(cpVect v)
    {
        v2f v2 = { cast(GLfloat)v.x, cast(GLfloat)v.y };
        return v2;
    }

    GLfloat x, y;
}

struct Vertex
{
    v2f vertex, aa_coord;
    Color fill_color, outline_color;
}

struct Triangle
{
    Vertex a, b, c;
}
