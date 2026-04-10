% Feature: F002
% Fixture: family knowledge base for functional testing

parent(tom, bob).
parent(tom, liz).
parent(bob, ann).
parent(bob, pat).

ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
