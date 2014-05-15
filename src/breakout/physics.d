/*
 *             Copyright Andrej Mitrovic 2013.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module breakout.physics;

import std.datetime;
import std.exception;
import std.math;
import std.random;
import std.stdio;
import std.string;

import dchip.all;

import breakout.draw;
import breakout.main;
import breakout.types;
import breakout.util;

// Vertically inverse 'U' box
cpSpace* space;

// Vertically inverse 'U' box
cpSpace* gameSpace;
cpBody* rogueBoxBody;
cpBody* playerBody;
cpShape* playerShape;

enum HasGravity { no, yes }
enum PassThrough { no, yes }

enum CollisionType : cpCollisionType
{
    sensor = 1,
    player = 2,
    brick = 3,
    ball = 4,
    bullet = 5,
    wall = 6,
}

enum Groups : cpGroup
{
    brick = 3,
    ball = 4,
    bullet = 5,
}

enum Layers : cpLayers
{
    all_objects = 1 << 1,
    gravity = 1 << 2,
    pass_through = 1 << 3,
    can_grab = 1 << 4,
    brick_killable = 1 << 5,
    brick_explosive = 1 << 6,
}

enum Velocities : float { neg = -200, pos = 200 }

// kill first collision object
bool noCollide(cpArbiter *arb, cpSpace *space, void*)
{
    return false;
}

cpVect rndVect()
{
    return cpVect(uniform!Velocities(), uniform!Velocities());
}

cpSpace* init()
{
    space = cpSpaceNew();
    gameSpace = space;

    createBox(space);
    //~ createUBox(space);

    //~ createSensor(space);
    //~ createPlayer(space);
    //~ createBricks(space);

    //~ fireBullets(PassThrough.no);

    // gravity ball
    createBall(space, PassThrough.no, HasGravity.yes, cpvzero, cpvzero);

    //~ foreach (i; 0 .. 5)
    //~ {
        //~ createBall(space, PassThrough.no, HasGravity.no,
            //~ cpVect(uniform(-200, 200), uniform(0, 200)), rndVect);
    //~ }

    setupCollisionHandlers();
    return space;
}

struct ScheduledAction
{
    // check whether this sequenced action should be called
    @property bool doAction()
    {
        if (doneAction)
            return false;

        if (curGameTick >= targetTick)
        {
            doneAction = true;
            return true;
        }

        return false;
    }

    void delegate() func;
    private ulong targetTick;
    private bool doneAction;  // only do the action once
}

// todo: it should be an O(1) removable list.
ScheduledAction[] scheduledActions;

/** Get the game tick index for when the current game tick will exhaust time. */
ulong getGameTick(Duration time)
{
    double timeSecs = (cast(TickDuration)time).to!("seconds", double);
    return curGameTick + cast(ulong)(timeSecs * ticksPerSec);
}

// todo: check if func was already added, we don't want to sequence duplicate actions.
void scheduleAction(Duration time, void delegate() func)
{
    scheduledActions ~= ScheduledAction(func, time.getGameTick);
}

void doScheduledActions()
{
    // note: has to be ref
    foreach (ref scheduledAction; scheduledActions)
    {
        if (scheduledAction.doAction)
        {
            scheduledAction.func();
        }
    }
}

ulong curGameTick;

immutable ticksPerSec = 60.0;

void update(cpSpace* space, double dt)
{
    ++curGameTick;

    //~ stderr.writefln("dt: %s", dt);

    if (playerBody !is null)
    {
        auto oldPos = cpBodyGetPos(playerBody);

        // using keyboard left/right with keyboard repeat
        auto newPos = cpVect((2 * ChipmunkDemoKeyboard.x) + oldPos.x, oldPos.y);

        // using a mouse, no repeat
        //~ auto newPos = cpVect(ChipmunkDemoMouse.x, oldPos.y);

        auto leftPos = -(curWindowWidth / 2);
        auto rightPos = (curWindowWidth / 2);

        // left-most and right-most point in world from center of player shape
        auto playerLeftMost = leftPos + ((playerShape.bb.r - playerShape.bb.l) / 2);
        auto playerRightMost = rightPos - ((playerShape.bb.r - playerShape.bb.l) / 2);

        // limit to left/right edges
        newPos.x = max(playerLeftMost, newPos.x);
        newPos.x = min(playerRightMost, newPos.x);

        cpBodySetPos(playerBody, newPos);
        cpBodyUpdatePosition(playerBody, dt);
    }

    cpSpaceStep(space, dt);

    doScheduledActions();
}

/** Kill this explosive brick now and trigger explosion to other bricks nearby. */
void killExplosiveBrick(cpShape* brick, cpSpace* space)
{
    // needed since a brick which triggered an explosion might be marked for destruction
    // again during multiple explosions, e.g. bricks:
    // [1] [2] -> Once [2] is destroyed it might trigger destruction of [1] again.
    if (brick.body_ is null || !cpSpaceContainsBody(space, brick.body_))
        return;

    float brickWidth = brick.bb.r - brick.bb.l;
    float brickHeight = brick.bb.t - brick.bb.b;

    float halfWidth = brickWidth / 2.0;
    float halfHeight = brickHeight / 2.0;

    // x and y origins are always in the center
    auto xOrigin = brick.body_.p.x - halfWidth;
    auto yOrigin = brick.body_.p.y - halfHeight;

    // left, bottom, right, top
    auto horLeft = xOrigin - halfWidth;
    auto horBottom = yOrigin;
    auto horRight = horLeft + (2 * brickWidth);
    auto horTop = horBottom + brickHeight;

    // left, bottom, right, top
    auto horBB = cpBB(horLeft, horBottom, horRight, horTop);

    // left, bottom, right, top
    auto verLeft = xOrigin;
    auto verBottom = yOrigin - halfHeight;
    auto verRight = verLeft + brickWidth;
    auto verTop = verBottom + (2 * brickHeight);

    // left, bottom, right, top
    auto verBB = cpBB(verLeft, verBottom, verRight, verTop);

    // debug draw
    version (none)
    queueRender(1.seconds, {
        ChipmunkDebugDrawBB(horBB, RGBAColor(1.0, 1.0, 1.0, 1.0), RGBAColor(1.0, 1.0, 1.0, 1.0));
        ChipmunkDebugDrawBB(verBB, RGBAColor(1.0, 1.0, 1.0, 1.0), RGBAColor(1.0, 1.0, 1.0, 1.0));
    });

    static void handleNeighborShapes(cpShape* shape, void* spacePtr)
    {
        auto space = cast(cpSpace*)spacePtr;

        if (shape && shape.group == Groups.brick && cpSpaceContainsBody(space, shape.body_))
        {
            scheduleAction(1.seconds, {
                killExplosiveBrick(shape, space);
            });
        }
    }

    // todo: we should have push/pop for layers
    auto layers = brick.layers;
    brick.layers = 0;  // remove layer so it's not picked up

    cpSpaceBBQuery(space, horBB, CP_ALL_LAYERS, CP_NO_GROUP, &handleNeighborShapes, space);
    cpSpaceBBQuery(space, verBB, CP_ALL_LAYERS, CP_NO_GROUP, &handleNeighborShapes, space);

    brick.layers = brick.layers;

    // kill this brick
    killBrick(brick, space);
}

/** Kill this brick now. */
void killBrick(cpShape* brick, cpSpace* space)
{
    // todo: we should add debug printouts here since it will show that our code is
    // doing needless work on dead bodies.
    if (!cpSpaceContainsBody(space, brick.body_))
        return;

    // note: could be set already if two balls or bullets end up hitting a brick at the same time
    if (cpSpaceGetPostStepCallback(space, brick) is null)
        enforce(cpSpaceAddPostStepCallback(space, &removeBody, brick, null));
}

void setupCollisionHandlers()
{
    cpSpaceAddCollisionHandler(space, CollisionType.bullet, CollisionType.ball, null, &noCollide, null, null, null);

    // both bullets and balls have the same handler
    static bool ball_bullet_brick(cpArbiter *arb, cpSpace *space, void*)
    {
        cpShape* ball_or_bullet;
        cpShape* brick;
        cpArbiterGetShapes(arb, &ball_or_bullet, &brick);

        const bool isPassThrough = (ball_or_bullet.layers & Layers.pass_through) == Layers.pass_through;
        const bool isBrickKillable = (brick.layers & Layers.brick_killable) == Layers.brick_killable;
        const bool isBrickExplosive = (brick.layers & Layers.brick_explosive) == Layers.brick_explosive;

        // if it was a bullet and it's not pass_through or the brick is unkillable, we have to kill the bullet
        if (ball_or_bullet.group == Groups.bullet && (!isBrickKillable || !isPassThrough))
        {
            // note: not sure if possible, but if two bricks end up touching a bullet it should only
            // be removed once.
            if (cpSpaceGetPostStepCallback(space, ball_or_bullet) is null)
                enforce(cpSpaceAddPostStepCallback(space, &removeBody, ball_or_bullet, null));
        }

        // bounce off of unkillable bricks, and don't kill the brick
        if (ball_or_bullet.group == Groups.ball && !isBrickKillable)
            return true;

        if (isBrickKillable)
        {
            if (isBrickExplosive)
                killExplosiveBrick(brick, space);
            else
                killBrick(brick, space);
        }

        // return value: true => bounce, false => don't bounce. Bounce only if not pass-through.
        return !isPassThrough;
    }

    cpSpaceAddCollisionHandler(space, CollisionType.ball, CollisionType.brick, null, &ball_bullet_brick, null, null, null);
    cpSpaceAddCollisionHandler(space, CollisionType.bullet, CollisionType.brick, null, &ball_bullet_brick, null, null, null);

    // bullets hitting any wall or sensor should die
    static bool bullet_wall_sensor(cpArbiter *arb, cpSpace *space, void*)
    {
        cpShape* bullet;
        cpShape* wall;
        cpArbiterGetShapes(arb, &bullet, &wall);

        // note: if a bullet has hit both the wall and the sensor it should be removed only once.
        if (cpSpaceGetPostStepCallback(space, bullet) is null)
            enforce(cpSpaceAddPostStepCallback(space, &removeBody, bullet, null));

        return false;
    }

    cpSpaceAddCollisionHandler(space, CollisionType.bullet, CollisionType.wall, null, &bullet_wall_sensor, null, null, null);
    cpSpaceAddCollisionHandler(space, CollisionType.bullet, CollisionType.sensor, null, &bullet_wall_sensor, null, null, null);

    static bool ball_player(cpArbiter *arb, cpSpace *space, void *data)
    {
        cpShape* ball;
        cpShape* paddle;
        cpArbiterGetShapes(arb, &ball, &paddle);

        cpVect oldVel = cpBodyGetVel(ball.body_);

        // ball position relative to the center of the paddle
        float diff = ball.body_.p.x - paddle.body_.p.x;

        auto paddleWidth = paddle.bb.r - paddle.bb.l;
        float halfWidth = paddleWidth / 2.0;

        // we want the paddle to represent a velocity range of [-200 .. 0 .. 200]
        float step = 200.0 / halfWidth;

        float newX = step * diff;
        float newY = 200;  // velocity should increase for realism.

        cpVect newVel = cpVect(newX, newY);

        cpBodySetVel(ball.body_, newVel);

        return false;
    }

    cpSpaceAddCollisionHandler(space, CollisionType.ball, CollisionType.player, null, &ball_player, null, null, null);

    // players and bullets should never collide
    // todo: we set bullets to die,
    // however we need to ensure bullets are not spawned onto the player
    // (or they will either die immediately)
    static bool bullet_player(cpArbiter *arb, cpSpace *space, void*)
    {
        cpShape* bullet;
        cpShape* player;
        cpArbiterGetShapes(arb, &bullet, &player);

        enforce(cpSpaceAddPostStepCallback(space, &removeBody, bullet, null));
        return false;
    }

    cpSpaceAddCollisionHandler(space, CollisionType.bullet, CollisionType.player, null, &bullet_player, null, null, null);

    static bool ball_sensor(cpArbiter *arb, cpSpace *space, void *data)
    {
        cpShape* ball;
        cpShape* sensor;
        cpArbiterGetShapes(arb, &ball, &sensor);

        enforce(cpSpaceAddPostStepCallback(space, &removeBody, ball, null));
        return true;
    }

    // todo: handle ball with wall as well
    // todo: we should get rid of situations where a ball has a very small X/Y value,
    // since this would make the ball take a very long time to get back to a pad.
    cpSpaceAddCollisionHandler(space, CollisionType.ball, CollisionType.sensor, &ball_sensor, null, null, null, null);
}

void makeBullet(PassThrough pass, cpVect a, cpVect b, cpVect velocity)
{
    cpBody* body_ = cpSpaceAddBody(space, cpBodyNew(1.0, 1.0));

    auto shape = cpSegmentShapeNew(body_, a, b, 1.0);
    cpShapeSetCollisionType(shape, CollisionType.bullet);
    cpShapeSetGroup(shape, Groups.bullet);

    shape.layers = Layers.all_objects;
    shape.layers |= Layers.can_grab;

    if (pass)
        shape.layers |= Layers.pass_through;

    cpSpaceAddShape(space, shape);

    cpBodyApplyImpulse(body_, velocity, cpvzero);
}

void fireBullets(PassThrough pass)
{
    if (playerShape is null)
        return;

    static void makeBulletFromCenter(PassThrough pass, cpVect velocity, cpVect offset)
    {
        cpVect a = cpvadd(playerBody.p, offset);
        cpVect b = cpvadd(a, cpVect(0, 10));
        makeBullet(pass, a, b, velocity);
    }

    cpVect velocity = cpVect(0, 100);

    float x = (playerShape.bb.r - playerShape.bb.l) / 3.0;
    float y = ((playerShape.bb.t - playerShape.bb.b) / 2.0) + 10;  // above the player

    cpVect offset = cpVect(x, y);
    makeBulletFromCenter(pass, velocity, offset);

    offset.x = -offset.x;
    makeBulletFromCenter(pass, velocity, offset);
}

float maxDist = 95.0;
cpFloat gravity = 3.2e7;

//~ struct GravitySegment
//~ {
    //~ bool hasTargets;

    //~ cpVect source;

    //~ // todo: remove hardcoding
    //~ cpVect[16] targets;

    //~ size_t ballCount;
//~ }

//~ // todo: this just handles one gravity ball
//~ GravitySegment gravitySegment;

struct GravityBall
{
    cpBody* body_;
}

GravityBall[] gravityBalls;

// todo: maybe we should override cpBodyUpdatePosition as well
void ballVelocityFunc(cpBody* body_, cpVect g, cpFloat damping, cpFloat dt)
{
    immutable minMax = 1500.0;

    auto pos = cpBodyGetPos(body_);
    auto space = gameSpace;

    cpShape* shape = body_.shapeList;

    // temporarily make the shape invisible so we pick up other closest-shapes and not this one.
    auto oldLayers = shape.layers;
    shape.layers = 0;

    cpNearestPointQueryInfo nearestInfo;
    cpSpaceNearestPointQueryNearest(space, pos, maxDist, Layers.gravity, CP_NO_GROUP, &nearestInfo);

    if (nearestInfo.shape && nearestInfo.shape.group == Groups.ball)
    {
        // only apply gravity if there's no blocking path between the target and the gravity ball.
        // todo: zero-out the layer and then check if theres no objects in-between.
        cpSegmentQueryInfo segInfo = {};
        if (cpSpaceSegmentQueryFirst(space, pos, nearestInfo.p, CP_ALL_LAYERS, CP_NO_GROUP, &segInfo))
        {
            cpVect point = cpSegmentQueryHitPoint(pos, nearestInfo.p, segInfo);

            version (none)  // debug draw
            ChipmunkDebugDrawSegment(pos, point, RGBAColor(0.0, 1.0, 0.0, 1.0));

            // straight line, apply gravity
            if (segInfo.shape is nearestInfo.shape)
            {
                version (none)  // debug draw
                queueRender(1.seconds, {
                    ChipmunkDebugDrawFatSegment(pos, nearestInfo.p, 0.5,
                        RGBAColor(1, 0.0, 0.0, 1.0), RGBAColor(1, 0.0, 0.0, 1.0));
                });

                // Gravitational acceleration is proportional to the inverse square of
                // distance, and directed toward the origin. The central planet is assumed
                // to be massive enough that it affects the satellites but not vice versa.
                cpVect  p      = cpvsub(pos, nearestInfo.shape.body_.p);
                cpFloat sqdist = cpvlengthsq(p);
                g = cpvmult(p, -gravity / (sqdist * cpfsqrt(sqdist)));
            }
        }
    }

    shape.layers = oldLayers;

    g.x = min(max(g.x, -minMax), minMax);
    g.y = min(max(g.y, -minMax), minMax);

    cpBodyUpdateVelocity(body_, g, damping, dt);
}

void createBall(cpSpace* space, PassThrough pass, HasGravity hasGravity, cpVect pos, cpVect velocity)
{
    cpFloat radius = 10;
    cpFloat mass = 1;

    if (hasGravity)
        radius = 12;

    cpFloat moment = cpMomentForCircle(mass, 0, radius, cpvzero);

    // todo: set to INFINITY to disallow mouse velocity
    cpBody* ballBody = cpSpaceAddBody(space, cpBodyNew(mass, INFINITY));

    ballBody.velocity_func = &ballVelocityFunc;

    cpBodySetPos(ballBody, pos);

    auto circleShape = cpCircleShapeNew(ballBody, radius, cpvzero);
    cpShapeSetGroup(circleShape, Groups.ball);
    cpShapeSetElasticity(circleShape, 1);

    circleShape.layers = Layers.all_objects;

    if (hasGravity)
        circleShape.layers |= Layers.gravity;

    if (pass)
        circleShape.layers |= Layers.pass_through;

    circleShape.layers |= Layers.can_grab;

    cpShapeSetCollisionType(circleShape, CollisionType.ball);

    cpShape* ballShape = cpSpaceAddShape(space, circleShape);
    cpShapeSetFriction(ballShape, 0);

    cpBodyApplyImpulse(ballBody, velocity, cpvzero);

    if (hasGravity)
        gravityBalls ~= GravityBall(ballBody);
}

void createWall(cpVect a, cpVect b)
{
    auto shape = cpSpaceAddShape(space, cpSegmentShapeNew(space.staticBody, a, b, 1.0f));
    cpShapeSetCollisionType(shape, CollisionType.wall);
    cpShapeSetElasticity(shape, 1.0f);
    shape.layers = Layers.all_objects;
}

/** Create a full '[]' box. */
void createBox(cpSpace* space)
{
    auto leftPos = -(curWindowWidth / 2);
    auto rightPos = (curWindowWidth / 2);
    auto topPos = (curWindowHeight / 2);
    auto bottomPos = -(curWindowHeight / 2);

    cpVect a = cpv(leftPos,  bottomPos);
    cpVect b = cpv(leftPos,  topPos);
    cpVect c = cpv(rightPos, topPos);
    cpVect d = cpv(rightPos, bottomPos);

    createWall(a, b);
    createWall(b, c);
    createWall(c, d);
    createWall(d, a);
}

void removeBody(cpSpace *space, void *obj, void*)
{
    auto shape = cast(cpShape*)obj;

    // Note: we have to remove the mouse attachment here before deleting the objects.
    if (mouse_joint && (mouse_joint.a is shape.body_ || mouse_joint.b is shape.body_))
    {
        cpSpaceRemoveConstraint(space, mouse_joint);
        cpConstraintFree(mouse_joint);
        mouse_joint = null;
    }

    cpSpaceRemoveBody(space, shape.body_);
    cpBodyFree(shape.body_);

    cpSpaceRemoveShape(space, shape);
    cpShapeFree(shape);

    // rogue bodies do not belong to a space
    //~ if (!cpBodyIsRogue(body_))
    //~ {
        //~ cpSpaceRemoveShape(space, shape);
        //~ cpSpaceRemoveBody(space, body_);
    //~ }

    //~ cpBodyFree(body_);
    //~ cpShapeFree(shape);
}

/** Create the bottom of the inverse 'U' box, which will simply kill of falling objects. */
void createSensor(cpSpace* space)
{
    auto leftPos = -(curWindowWidth / 2);
    auto rightPos = (curWindowWidth / 2);
    auto bottomPos = -(curWindowHeight / 2);

    cpVect a = cpv(leftPos, bottomPos);
    cpVect b = cpv(rightPos, bottomPos);

    auto shape = cpSpaceAddShape(space, cpSegmentShapeNew(space.staticBody, a, b, 0.0f));

    // Sensors only call collision callbacks, and never generate real collisions.
    cpShapeSetSensor(shape, cpTrue);

    cpShapeSetCollisionType(shape, CollisionType.sensor);
}

enum BrickKillable { no, yes }
enum BrickExplosive { no, yes }

void createBrick(cpSpace* space, cpVect pos, cpVect size, BrickKillable killable, BrickExplosive explosive)
{
    // note: static bodies cannot be removed
    auto brick = cpBodyNew(INFINITY, INFINITY);
    cpBodySetPos(brick, pos);

    auto shape = cpBoxShapeNew(brick, size.x, size.y);
    shape.layers = Layers.all_objects;

    cpShapeSetGroup(shape, Groups.brick);

    if (killable)
        shape.layers |= Layers.brick_killable;

    if (explosive)
        shape.layers |= Layers.brick_explosive;

    cpShape* brickShape = cpSpaceAddShape(space, shape);
    cpShapeSetElasticity(brickShape, 1);

    cpShapeSetCollisionType(brickShape, CollisionType.brick);

    cpSpaceAddBody(space, brick);
}

void createBricks(cpSpace* space)
{
    foreach (i; 0 .. 10)
    {
        createBrick(space, cpVect((i * 40) - 150, 100), cpVect(40, 20), BrickKillable.yes, BrickExplosive.yes);
        createBrick(space, cpVect((i * 40) - 150, 50), cpVect(40, 20), BrickKillable.no, BrickExplosive.no);
    }
}

void createPlayer(cpSpace* space)
{
    playerBody = cpBodyNew(INFINITY, INFINITY);
    playerShape = cpBoxShapeNew(playerBody, 200.0, 10.0);

    cpShape* playerCpShape = cpSpaceAddShape(space, playerShape);
    playerCpShape.layers = Layers.all_objects;
    cpShapeSetElasticity(playerCpShape, 1);

    auto bottomPos = -(curWindowHeight / 2);

    cpBodySetPos(playerBody, cpVect(0.0, bottomPos + 50));

    cpShapeSetCollisionType(playerCpShape, CollisionType.player);
}

void destroy(cpSpace* space)
{
    ChipmunkDemoFreeSpaceChildren(space);
    cpSpaceFree(space);
}

ChipmunkDemo physics = {
    "Breakout",
    1.0 / ticksPerSec,
    &init,
    &update,
    &ChipmunkDemoDefaultDrawImpl,
    &destroy,
};
