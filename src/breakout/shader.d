/*
 *             Copyright Andrej Mitrovic 2013.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module breakout.shader;

import std.conv;
import std.stdio;
import std.string;

import dchip.all;

import glad.gl.all;
import glad.gl.loader;

auto CHECK_GL_ERRORS() { CheckGLErrors(); }

string SET_ATTRIBUTE(string program, string type, string name, string gltype)
{
    return q{
        SetAttribute(program, "%1$s", %2$s.%1$s.sizeof / GLfloat.sizeof, %3$s, %2$s.sizeof, cast(GLvoid *)%2$s.%1$s.offsetof);
    }.format(name, type, gltype);
}

/// Converts an OpenGL errorenum to a string
string toString(GLenum error)
{
    switch (error)
    {
        case GL_INVALID_ENUM:
            return "An unacceptable value is specified for an enumerated argument.";

        case GL_INVALID_VALUE:
            return "A numeric argument is out of range.";

        case GL_INVALID_OPERATION:
            return "The specified operation is not allowed in the current state.";

        case GL_INVALID_FRAMEBUFFER_OPERATION:
            return "The framebuffer object is not complete.";

        case GL_OUT_OF_MEMORY:
            return "There is not enough memory left to execute the command. WARNING: GL operation is undefined.";

        case GL_STACK_UNDERFLOW:
            return "An attempt has been made to perform an operation that would cause an internal stack to underflow.";

        case GL_STACK_OVERFLOW:
            return "An attempt has been made to perform an operation that would cause an internal stack to overflow.";

        default:
            assert(0, format("Unhandled GLenum error state: '%s'", error));
    }
}

void CheckGLErrors()
{
    for (GLenum err = glGetError(); err; err = glGetError())
    {
        if (err)
        {
            stderr.writefln("Error: - %s", err.toString());
            stderr.writefln("GLError(%s:%d) 0x%04X\n", __FILE__, __LINE__, err);
            assert(0);
        }
    }
}

alias PFNGLGETSHADERIVPROC = fp_glGetShaderiv;
alias PFNGLGETSHADERINFOLOGPROC = fp_glGetProgramInfoLog;

//typedef GLAPIENTRY void (*GETIV)(GLuint shader, GLenum pname, GLint *params);
//typedef GLAPIENTRY void (*GETINFOLOG)(GLuint shader, GLsizei maxLength, GLsizei *length, GLchar *infoLog);

static cpBool CheckError(GLint obj, GLenum status, PFNGLGETSHADERIVPROC getiv, PFNGLGETSHADERINFOLOGPROC getInfoLog)
{
    GLint success;
    getiv(obj, status, &success);

    if (!success)
    {
        GLint length;
        getiv(obj, GL_INFO_LOG_LENGTH, &length);

        char* log = cast(char*)alloca(length);
        getInfoLog(obj, length, null, log);

        stderr.writefln("Shader compile error for 0x%04X: %s\n", status, log.to!string);
        return cpFalse;
    }
    else
    {
        return cpTrue;
    }
}

GLint CompileShader(GLenum type, string source)
{
    GLint shader = glCreateShader(type);

    auto ssp = source.ptr;
    int ssl = cast(int)(source.length);
    glShaderSource(shader, 1, &ssp, &ssl);
    glCompileShader(shader);

    // TODO return placeholder shader instead?
    cpAssertHard(CheckError(shader, GL_COMPILE_STATUS, glGetShaderiv, glGetShaderInfoLog), "Error compiling shader");

    return shader;
}

GLint LinkProgram(GLint vshader, GLint fshader)
{
    GLint program = glCreateProgram();

    glAttachShader(program, vshader);
    glAttachShader(program, fshader);
    glLinkProgram(program);

    // todo return placeholder program instead?
    cpAssertHard(CheckError(program, GL_LINK_STATUS, glGetProgramiv, glGetProgramInfoLog), "Error linking shader program");

    return program;
}

cpBool ValidateProgram(GLint program)
{
    // TODO
    return cpTrue;
}

void SetAttribute(GLuint program, string name, GLint size, GLenum gltype, GLsizei stride, GLvoid* offset)
{
    GLint index = glGetAttribLocation(program, name.toStringz);
    glEnableVertexAttribArray(index);
    glVertexAttribPointer(index, size, gltype, GL_FALSE, stride, offset);
}
