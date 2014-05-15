/*
 *             Copyright Andrej Mitrovic 2013.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module breakout.util;

auto min(A, B)(A a, B b)
{
    return a < b ? a : b;
}

auto max(A, B)(A a, B b)
{
    return a > b ? a : b;
}
